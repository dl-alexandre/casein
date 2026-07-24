defmodule CaseinPreviewBrowser.AdapterTest do
  use ExUnit.Case, async: true

  alias CaseinPreviewBrowser.Adapter

  @preview_ctl_callbacks [
    start_session: 1,
    navigate: 2,
    go_back: 1,
    go_forward: 1,
    reload: 1,
    observe: 1,
    observe_live: 1,
    click: 2,
    type: 4,
    press: 2,
    screenshot: 1,
    get_storage: 1,
    clear_storage: 1,
    record_start: 2,
    record_stop: 1,
    close: 1
  ]

  test "exports the PreviewCtl adapter-shaped function set" do
    assert {:module, Adapter} = Code.ensure_loaded(Adapter)

    for {name, arity} <- @preview_ctl_callbacks do
      assert function_exported?(Adapter, name, arity)
    end
  end

  test "requires a current URL when starting a session" do
    assert {:error, :missing_url} = Adapter.start_session(%{})
  end

  test "starts a browser session, navigates, observes, and emits events" do
    assert {:ok, state} =
             Adapter.start_session(%{
               current_url: "about:blank",
               event_owner: self()
             })

    assert state.current_url == "about:blank"

    assert {:ok, state, observation} =
             Adapter.navigate(state, "http://127.0.0.1:4000/preview")

    assert state.current_url == "http://127.0.0.1:4000/preview"
    assert observation.url == "http://127.0.0.1:4000/preview"
    assert observation.status == 200

    assert_receive {:preview_browser, _browser_id,
                    {:load_started, "http://127.0.0.1:4000/preview"}}

    assert_receive {:preview_browser, _browser_id,
                    {:load_finished, "http://127.0.0.1:4000/preview", 200}}

    assert {:ok, observed} = Adapter.observe(state)
    assert observed.url == "http://127.0.0.1:4000/preview"

    assert {:ok, state, live_observation} = Adapter.observe_live(state)
    assert state.last_observation == live_observation
  end

  test "reload navigates to the current URL" do
    {:ok, state} = Adapter.start_session(%{current_url: "http://example.test"})

    assert {:ok, state, observation} = Adapter.reload(state)
    assert state.current_url == "http://example.test"
    assert observation.url == "http://example.test"
  end

  test "captures screenshot metadata and a PreviewCtl-compatible PNG artifact" do
    {:ok, state} = Adapter.start_session(%{current_url: "http://example.test"})

    assert {:ok, state, observation, "data:image/png;base64," <> encoded} =
             Adapter.screenshot(state)

    assert state.last_observation == observation
    assert observation.screenshot.mime_type == "image/png"
    assert observation.screenshot.byte_size > 0
    assert Base.decode64!(encoded) =~ "http://example.test"
  end

  test "unsupported callbacks are explicit" do
    {:ok, state} = Adapter.start_session(%{current_url: "about:blank"})

    assert {:error, {:unsupported_operation, :go_back}} = Adapter.go_back(state)
    assert {:error, {:unsupported_operation, :go_forward}} = Adapter.go_forward(state)
    assert {:error, {:unsupported_operation, :click}} = Adapter.click(state, %{selector: "main"})
    assert {:error, {:unsupported_operation, :type}} = Adapter.type(state, "input", "text", %{})
    assert {:error, {:unsupported_operation, :press}} = Adapter.press(state, "Enter")
    assert {:error, {:unsupported_operation, :get_storage}} = Adapter.get_storage(state)
    assert {:error, {:unsupported_operation, :clear_storage}} = Adapter.clear_storage(state)
    assert {:error, {:unsupported_operation, :record_start}} = Adapter.record_start(state, [])
    assert {:error, {:unsupported_operation, :record_stop}} = Adapter.record_stop(state)
  end

  test "close stops the runtime process" do
    {:ok, %{session: session} = state} = Adapter.start_session(%{current_url: "about:blank"})
    ref = Process.monitor(session)

    assert :ok = Adapter.close(state)
    assert_receive {:DOWN, ^ref, :process, ^session, :normal}
  end
end
