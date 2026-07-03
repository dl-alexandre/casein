defmodule DevIDE.PreviewPanesExtraTest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewPanes
  alias DevIDE.Previews.ControlSession
  alias DevIde.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_app_url = Application.get_env(:dev_ide, :preview_app_url)
    prev_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    prev_proxy = Application.get_env(:dev_ide, :preview_proxy_enabled)
    prev_persistence = Application.get_env(:dev_ide, :preview_pane_persistence_enabled)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    Application.put_env(:dev_ide, :preview_pane_persistence_enabled, true)
    PreviewPanes.clear()
    FakeState.delete(:fake_tmux_windows)
    FakeState.delete(:fake_tmux_panes)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      restore(:tmux_adapter, prev_tmux)
      restore(:workspaces_root, prev_root)
      restore(:preview_app_url, prev_app_url)
      restore(:preview_loopback_port, prev_loopback)
      restore(:preview_proxy_enabled, prev_proxy)
      restore(:preview_pane_persistence_enabled, prev_persistence)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root =
      Path.join(
        System.tmp_dir!(),
        "preview-panes-extra-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {root, path}
  end

  defp seed_session!(session, pane_id) do
    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        }
      ]
    })
  end

  defp register_pane!(session, pane_id, path, extra \\ %{}) do
    attrs =
      Map.merge(
        %{
          "pane_id" => pane_id,
          "url" => "http://localhost:5173/",
          "cwd" => path,
          "tmux_session" => session
        },
        extra
      )

    assert {:ok, registration} = PreviewPanes.register(attrs)
    registration
  end

  # ---- register: input validation / error branches ----------------------------

  test "register without a url returns missing_url" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_nourl"
    pane_id = "%30"
    seed_session!(session, pane_id)

    assert {:error, :missing_url} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "cwd" => path,
               "tmux_session" => session
             })
  end

  test "register with an untrusted external http url returns untrusted_url" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_untrusted"
    pane_id = "%32"
    seed_session!(session, pane_id)

    # A non-loopback, non-allowed origin is rejected by validate_trusted_url/2.
    assert {:error, :untrusted_url} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "ftp://example.com/foo",
               "cwd" => path,
               "tmux_session" => session
             })
  end

  test "register resolves a workspace from a workspace map when no cwd is given" do
    session = "devide_ws_extra_wsmap"
    pane_id = "%33"
    seed_session!(session, pane_id)

    workspace = %{
      id: "ws-extra-map",
      name: "extra-map",
      path: "/tmp",
      metadata: %{detected_ports: [5173]}
    }

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "workspace" => workspace,
               "tmux_session" => session
             })

    assert registration.workspace_id == "ws-extra-map"
    assert registration.pane_id == pane_id
  end

  test "register normalizes a bare :port url to a localhost url" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_bareport"
    pane_id = "%34"
    seed_session!(session, pane_id)

    registration = register_pane!(session, pane_id, path, %{"url" => ":5173"})
    assert registration.url == "http://localhost:5173/"
  end

  test "register normalizes a bare :port url with a path" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_bareport_path"
    pane_id = "%35"
    seed_session!(session, pane_id)

    registration = register_pane!(session, pane_id, path, %{"url" => ":5173/dashboard"})
    assert registration.url == "http://localhost:5173/dashboard"
  end

  test "register ignores a malformed viewport string" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_badviewport"
    pane_id = "%36"
    seed_session!(session, pane_id)

    registration = register_pane!(session, pane_id, path, %{"viewport" => "not-a-size"})
    assert registration.viewport == nil
  end

  test "register stores placement/anchor metadata when provided" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_placement"
    pane_id = "%37"
    seed_session!(session, pane_id)

    registration =
      register_pane!(session, pane_id, path, %{
        "placement" => "right",
        "anchor_pane_id" => "%anchor",
        "anchor_window_id" => "@9",
        "pane_window_id" => "@10"
      })

    assert registration.placement == "right"
    assert registration.anchor_pane_id == "%anchor"
    assert registration.anchor_window_id == "@9"
    assert registration.pane_window_id == "@10"
  end

  # ---- deregister --------------------------------------------------------------

  test "deregister an unknown pane returns not_found" do
    assert {:error, :not_found} = PreviewPanes.deregister("%does-not-exist")
  end

  # ---- navigate / history on missing panes ------------------------------------

  test "navigate on an unregistered pane returns not_found" do
    assert {:error, :not_found} = PreviewPanes.navigate("%missing-nav", "/settings")
  end

  test "go_back / go_forward / reload on an unregistered pane return not_found" do
    assert {:error, :not_found} = PreviewPanes.go_back("%missing-hist")
    assert {:error, :not_found} = PreviewPanes.go_forward("%missing-hist")
    assert {:error, :not_found} = PreviewPanes.reload("%missing-hist")
  end

  test "navigate to an untrusted preview url returns an error" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_nav_untrusted"
    pane_id = "%38"
    seed_session!(session, pane_id)
    _registration = register_pane!(session, pane_id, path)

    # Navigating to an absolute, non-allowed external origin fails the
    # require_trusted_preview_url/1 guard before any control navigation.
    assert {:error, :untrusted_url} =
             PreviewPanes.navigate(pane_id, "ftp://evil.example.com/foo")
  end

  # ---- click_snapshot error branches ------------------------------------------

  test "click_snapshot on an unregistered pane returns not_found" do
    assert {:error, :not_found} =
             PreviewPanes.click_snapshot("%missing-click", %{"x" => 1, "y" => 2})
  end

  test "click_snapshot on a non-snapshot pane returns not_snapshot_preview" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_click_nonsnap"
    pane_id = "%39"
    seed_session!(session, pane_id)
    _registration = register_pane!(session, pane_id, path, %{"viewport" => "120x80"})

    # The pane is a live iframe preview, not a /preview-artifacts/ snapshot, so
    # ensure_snapshot_registration/1 rejects the click.
    assert {:error, :not_snapshot_preview} =
             PreviewPanes.click_snapshot(pane_id, %{"x" => 10, "y" => 10})
  end

  test "click_snapshot with non-numeric coordinates is rejected on snapshot panes" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_click_badcoord"
    pane_id = "%40"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    registration = register_pane!(session, pane_id, path, %{"viewport" => "120x80"})

    assert {:ok, _snapshot} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/1.png"
             )

    assert {:error, :invalid_snapshot_click} =
             PreviewPanes.click_snapshot(pane_id, %{"x" => "abc", "y" => 5})
  end

  # ---- show_artifact error branches -------------------------------------------

  test "show_artifact for an unknown control session returns not_found" do
    assert {:error, :not_found} =
             PreviewPanes.show_artifact(987_654_321, "/preview-artifacts/x/1.png")
  end

  test "show_artifact rejects a path outside the artifacts root" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_badartifact"
    pane_id = "%41"
    seed_session!(session, pane_id)
    registration = register_pane!(session, pane_id, path)

    assert {:error, :invalid_artifact_path} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/not-an-artifact/1.png"
             )
  end

  test "show_artifact uses the playback fit for video artifacts" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_video"
    pane_id = "%42"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    registration = register_pane!(session, pane_id, path)

    assert {:ok, snapshot} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/clip.webm"
             )

    # artifact_fit/1 maps .webm to "playback" rather than "preview".
    assert snapshot.display_url =~ "?fit=playback"
    assert snapshot.display_url =~ "clip.webm"
  end

  # ---- sync_control_navigation -------------------------------------------------

  test "sync_control_navigation for an unknown session returns unchanged" do
    assert {:ok, :unchanged} =
             PreviewPanes.sync_control_navigation(123_456_789, "http://localhost:5173/foo")
  end

  test "sync_control_navigation returns unchanged when the display url is identical" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_sync_same"
    pane_id = "%43"
    seed_session!(session, pane_id)
    Application.put_env(:dev_ide, :preview_proxy_enabled, false)
    registration = register_pane!(session, pane_id, path)

    # Feeding back the same current_url the pane already displays resolves to the
    # same display_url, so do_sync_control_navigation/2 reports :unchanged.
    assert {:ok, :unchanged} =
             PreviewPanes.sync_control_navigation(
               registration.control_session_id,
               registration.url
             )
  end

  # ---- lookups: nil / empty branches ------------------------------------------

  test "get_by_pane returns nil for an unknown pane" do
    assert PreviewPanes.get_by_pane("%no-such-pane") == nil
  end

  test "get_by_session returns nil for an unknown session" do
    assert PreviewPanes.get_by_session(424_242) == nil
  end

  test "list_for_workspace and list_for_workspace_map are empty for an unknown workspace" do
    assert PreviewPanes.list_for_workspace("folder:unknown-extra") == []
    assert PreviewPanes.list_for_workspace_map("folder:unknown-extra") == %{}
  end

  test "list_for_workspace_map keys registrations by pane id" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_listmap"
    pane_id = "%44"
    seed_session!(session, pane_id)
    registration = register_pane!(session, pane_id, path)

    map = PreviewPanes.list_for_workspace_map(registration.workspace_id)
    assert Map.has_key?(map, pane_id)
    assert map[pane_id].pane_id == pane_id
  end

  # ---- public browser_display_url/1 and /2 ------------------------------------

  test "browser_display_url/1 rewrites a loopback url to a same-origin path" do
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)

    url = "http://localhost:4000/workspaces?tab=agents#preview"
    assert PreviewPanes.browser_display_url(url) == "/workspaces?tab=agents#preview"
  end

  test "browser_display_url/1 leaves a non-loopback url unchanged" do
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)

    assert PreviewPanes.browser_display_url("https://example.com/page") ==
             "https://example.com/page"
  end

  test "browser_display_url/1 passes through non-binary input" do
    assert PreviewPanes.browser_display_url(nil) == nil
  end

  test "browser_display_url/2 with a workspace rewrites loopback urls to paths" do
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)
    workspace = %{id: "folder:extra-bdu"}

    assert PreviewPanes.browser_display_url(workspace, "http://localhost:4000/settings") ==
             "/settings"
  end

  test "browser_display_url/2 falls back to the url when no workspace map matches" do
    assert PreviewPanes.browser_display_url(%{id: "folder:extra-bdu2"}, nil) == nil
  end

  # ---- session_terminated topology handler ------------------------------------

  test "session_terminated topology event deregisters that session's panes" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_terminated"
    pane_id = "%45"
    seed_session!(session, pane_id)
    registration = register_pane!(session, pane_id, path)

    assert PreviewPanes.get_by_pane(pane_id)

    send(
      Process.whereis(PreviewPanes),
      {DevIDE.Terminals.TmuxTopology, {:session_terminated, %{session: session}}}
    )

    _ = :sys.get_state(PreviewPanes)

    assert PreviewPanes.get_by_pane(pane_id) == nil
    assert Repo.get!(ControlSession, registration.control_session_id).status == :closed
  end

  test "list_for_workspace is not head-of-line blocked by slow browser navigate" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_async"
    pane_id = "%47"
    seed_session!(session, pane_id)
    registration = register_pane!(session, pane_id, path)

    prev_delay = Application.get_env(:dev_ide, :preview_panes_test_browser_delay_ms)
    Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, 400)

    on_exit(fn ->
      if prev_delay,
        do: Application.put_env(:dev_ide, :preview_panes_test_browser_delay_ms, prev_delay),
        else: Application.delete_env(:dev_ide, :preview_panes_test_browser_delay_ms)
    end)

    parent = self()

    slow_nav =
      spawn(fn ->
        send(parent, {:nav_started, self()})
        result = PreviewPanes.navigate(pane_id, "/settings")
        send(parent, {:nav_done, result})
      end)

    assert_receive {:nav_started, ^slow_nav}, 1_000

    t0 = System.monotonic_time(:millisecond)
    listed = PreviewPanes.list_for_workspace(registration.workspace_id)
    elapsed = System.monotonic_time(:millisecond) - t0

    assert length(listed) == 1

    assert elapsed < 200,
           "expected list_for_workspace to complete without waiting on browser I/O, took #{elapsed}ms"

    IO.puts(
      "[preview-panes-async] nav_started during slow navigate; " <>
        "list_for_workspace elapsed=#{elapsed}ms (<200ms threshold)"
    )

    assert_receive {:nav_done, {:ok, _}}, 5_000
  end

  # ---- unknown handle_info is ignored -----------------------------------------

  test "an unrelated info message leaves the registry intact" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_extra_noise"
    pane_id = "%46"
    seed_session!(session, pane_id)
    _registration = register_pane!(session, pane_id, path)

    send(Process.whereis(PreviewPanes), :some_unrelated_message)
    _ = :sys.get_state(PreviewPanes)

    assert PreviewPanes.get_by_pane(pane_id)
  end
end
