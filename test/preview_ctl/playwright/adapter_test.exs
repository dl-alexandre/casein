defmodule PreviewCtl.Playwright.AdapterTest do
  use ExUnit.Case, async: false

  alias PreviewCtl.Playwright.{Adapter, Bridge}

  setup do
    bypass = Bypass.open()
    previous_script = Application.get_env(:preview_ctl, :playwright_script)

    Application.put_env(
      :preview_ctl,
      :playwright_script,
      "test/support/preview_playwright_fake_daemon.cjs"
    )

    restart_bridge!()

    on_exit(fn ->
      put_or_delete_env(previous_script)
      restart_bridge!()
    end)

    {:ok, bypass: bypass, base_url: "http://localhost:#{bypass.port}"}
  end

  test "start_session requires a url and normalizes headers", %{base_url: base_url} do
    assert {:ok, state} =
             Adapter.start_session(%{
               current_url: base_url <> "/start",
               default_headers: %{"x-test" => "1", "" => "drop", "bad\nkey" => "drop"}
             })

    assert state.current_url == base_url <> "/start"
    assert state.browser_id =~ "pw-"
    assert state.default_headers == %{"x-test" => "1"}
    assert state.storage_profile == "ephemeral"

    assert {:error, :missing_url} = Adapter.start_session(%{})
  end

  test "navigate and observe summarize HTML over HTTP", %{bypass: bypass, base_url: base_url} do
    Bypass.stub(bypass, "GET", "/page", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
      |> Plug.Conn.resp(
        200,
        """
        <html><head><title>Preview</title><base href="https://origin.example/"></head>
        <body><h1>Heading</h1><a href="/next">Next</a><p>Visible</p></body></html>
        """
      )
    end)

    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/page"})
    assert {:ok, new_state, obs} = Adapter.navigate(state, base_url <> "/page")
    assert new_state.current_url == base_url <> "/page"
    assert obs.title == "Preview"
    assert obs.frame_blocked == true
    assert obs.dom_summary.headings == ["Heading"]
    assert obs.dom_summary.links == [%{href: "/next", text: "Next"}]
    assert obs.source_url == "https://origin.example/"

    assert {:ok, observe_only} = Adapter.observe(new_state)
    assert observe_only.title == "Preview"
  end

  test "navigate reports redirect and HTTP errors", %{bypass: bypass, base_url: base_url} do
    Bypass.expect_once(bypass, "GET", "/redirect", fn conn ->
      Plug.Conn.resp(conn, 302, "") |> Plug.Conn.put_resp_header("location", "/elsewhere")
    end)

    Bypass.expect_once(bypass, "GET", "/missing", fn conn ->
      Plug.Conn.resp(conn, 404, "not found")
    end)

    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/"})

    assert {:error, {:redirect_blocked, 302, "/elsewhere"}} =
             Adapter.navigate(state, base_url <> "/redirect")

    assert {:error, {:http_status, 404, "not found"}} =
             Adapter.navigate(state, base_url <> "/missing")
  end

  test "observe_live falls back to static observation when Playwright is unavailable" do
    Application.delete_env(:preview_ctl, :playwright_script)
    restart_bridge!()

    bypass = Bypass.open()

    on_exit(fn ->
      Application.put_env(
        :preview_ctl,
        :playwright_script,
        "test/support/preview_playwright_fake_daemon.cjs"
      )

      restart_bridge!()
    end)

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 200, "<html><title>Static</title><body>Hi</body></html>")
    end)

    url = "http://localhost:#{bypass.port}/"
    {:ok, state} = Adapter.start_session(%{current_url: url})

    assert {:ok, ^state, obs} = Adapter.observe_live(state)
    assert obs.title == "Static"
  end

  test "browser actions delegate to the Playwright bridge", %{base_url: base_url} do
    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/"})

    assert {:ok, new_state, obs} = Adapter.click(state, %{selector: "#go", nth: 1})
    assert obs.title == "Fake Page"
    assert obs.diff.diff_pct == 1.0
    assert new_state.current_url == base_url <> "/"

    assert {:ok, typed_state} =
             Adapter.type(new_state, "#input", "hello", %{nth: 0})

    assert typed_state.last_observation.diff.diff_pct == 1.0
    assert typed_state.current_url == base_url <> "/"

    assert {:ok, pressed_state} = Adapter.press(typed_state, "Enter")
    assert pressed_state.last_observation.diff.diff_pct == 1.0
    assert pressed_state.current_url == base_url <> "/"

    assert {:ok, back_state, _obs} = Adapter.go_back(pressed_state)
    assert {:ok, forward_state, _obs} = Adapter.go_forward(back_state)
    assert {:ok, reloaded_state, _obs} = Adapter.reload(forward_state)

    assert {:ok, live_state, live_obs} = Adapter.observe_live(reloaded_state)
    assert live_obs.title == "Fake Page"
    assert live_state.last_observation.title == "Fake Page"
  end

  test "screenshot returns artifact when Playwright is available", %{base_url: base_url} do
    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/"})

    assert {:ok, _state, _obs, "fake-screenshot"} = Adapter.screenshot(state)
  end

  test "screenshot falls back to simulated observation when Playwright is unavailable", %{
    bypass: bypass,
    base_url: base_url
  } do
    Application.delete_env(:preview_ctl, :playwright_script)
    restart_bridge!()

    Bypass.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 200, "<html><title>Static</title></html>")
    end)

    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/"})

    assert {:ok, _state, obs, nil} = Adapter.screenshot(state)
    assert obs.screenshot.simulated == true
  end

  test "storage and recording helpers decode bridge payloads", %{base_url: base_url} do
    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/app"})

    assert {:ok, storage_state, storage} = Adapter.get_storage(state)
    assert storage.local_storage == %{"key" => "value"}
    assert storage_state.last_storage.url == base_url <> "/app"

    assert {:ok, cleared_state, cleared} = Adapter.clear_storage(storage_state)
    assert cleared.local_storage == %{"key" => "value"}
    assert cleared_state.last_storage == cleared

    assert {:ok, _recording_state, %{recording_id: "rec-42"}} =
             Adapter.record_start(state,
               recording_id: "rec-42",
               dir: "/tmp/recordings",
               width: 1280,
               height: 720
             )

    assert {:ok, _stopped_state, %{video_path: "/tmp/fake.webm"}} = Adapter.record_stop(state)
  end

  test "decode_playwright_result whitelists diff on click observation", %{base_url: base_url} do
    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/"})

    assert {:ok, _state, obs} = Adapter.click(state, %{selector: "#go"})
    assert obs.diff.diff_pct == 1.0
    assert obs.diff.changed_regions != []
    assert obs.diff.diff_png_base64 =~ "data:image/png;base64,"
  end

  test "mutating actions omit diff when diff:false is passed", %{base_url: base_url} do
    {:ok, state} = Adapter.start_session(%{current_url: base_url <> "/"})

    assert {:ok, _state, obs} = Adapter.click(state, %{selector: "#go", diff: false})
    refute Map.has_key?(obs, :diff)

    assert {:ok, _state, obs} = Adapter.click(state, %{selector: "#go", diff: "false"})
    refute Map.has_key?(obs, :diff)

    assert {:ok, typed_state} =
             Adapter.type(state, "#input", "hello", %{diff: false, nth: 0})

    refute Map.has_key?(typed_state.last_observation, :diff)

    assert {:ok, typed_state} =
             Adapter.type(state, "#input", "hello", %{diff: "false", nth: 0})

    refute Map.has_key?(typed_state.last_observation, :diff)

    assert {:ok, pressed_state} = Adapter.press(typed_state, "Enter", %{diff: false})
    refute Map.has_key?(pressed_state.last_observation, :diff)

    assert {:ok, pressed_state} = Adapter.press(typed_state, "Enter", %{diff: "false"})
    refute Map.has_key?(pressed_state.last_observation, :diff)
  end

  test "close is a no-op without a browser id" do
    assert :ok = Adapter.close(%{})
  end

  defp restart_bridge! do
    _ = Supervisor.terminate_child(DevIde.Supervisor, Bridge)
    {:ok, _} = Supervisor.restart_child(DevIde.Supervisor, Bridge)
  end

  defp put_or_delete_env(nil), do: Application.delete_env(:preview_ctl, :playwright_script)

  defp put_or_delete_env(value),
    do: Application.put_env(:preview_ctl, :playwright_script, value)
end
