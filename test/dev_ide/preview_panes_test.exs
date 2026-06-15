defmodule DevIDE.PreviewPanesTest do
  use DevIde.DataCase, async: false

  alias DevIDE.PreviewPanes
  alias DevIDE.Previews.ControlSession
  alias DevIDE.Terminals.TmuxTopology
  alias DevIde.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_app_url = Application.get_env(:dev_ide, :preview_app_url)
    prev_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
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
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, val), do: Application.put_env(:dev_ide, key, val)

  defp seed_workspace! do
    root = Path.join(System.tmp_dir!(), "preview-panes-#{System.unique_integer([:positive])}")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:dev_ide, :workspaces_root, root)
    {root, path}
  end

  defp seed_session!(session, pane_id \\ "%1") do
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

  test "register creates preview pane registration and broadcasts" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_1"
    pane_id = "%9"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "preview:" <> workspace_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => ":5173",
               "cwd" => path,
               "tmux_session" => session
             })

    assert registration.pane_id == pane_id
    assert registration.url == "http://localhost:5173/"
    assert is_binary(registration.display_url)
    assert registration.workspace_id

    assert_receive {:preview_pane_registered, payload}
    assert payload.pane_id == pane_id
  end

  test "register accepts external http preview URLs" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_external"
    pane_id = "%12"
    url = "https://www.whitehouse.gov/"
    seed_session!(session, pane_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => url,
               "cwd" => path,
               "tmux_session" => session
             })

    assert registration.pane_id == pane_id
    assert registration.url == url
    assert registration.display_url == url
  end

  test "register uses loopback control URL for DevIDE-hosted display URLs" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_devide_host"
    pane_id = "%13"
    display_url = "https://devide.example.com/whitehouse-preview.html"
    seed_session!(session, pane_id)
    Application.put_env(:dev_ide, :preview_app_url, "https://devide.example.com")
    Application.put_env(:dev_ide, :preview_loopback_port, 4100)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => display_url,
               "cwd" => path,
               "tmux_session" => session
             })

    session = Repo.get!(ControlSession, registration.control_session_id)
    assert registration.display_url == display_url
    assert session.current_url == "http://127.0.0.1:4100/whitehouse-preview.html"
    assert session.metadata["display_url"] == display_url
    assert session.metadata["control_url"] == "http://127.0.0.1:4100/whitehouse-preview.html"
    assert "http://localhost:4100" in session.metadata["allowed_origins"]
  end

  test "navigate updates pane registration and broadcasts the new display URL" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_nav"
    pane_id = "%14"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "preview:" <> workspace_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, navigated} = PreviewPanes.navigate(pane_id, "/settings")

    assert navigated.control_session_id == registration.control_session_id
    assert navigated.display_url == "http://localhost:5173/settings"
    assert PreviewPanes.get_by_pane(pane_id).display_url == "http://localhost:5173/settings"
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id, display_url: display_url}}
    assert display_url == "http://localhost:5173/settings"
  end

  test "double register replaces the existing pane registration" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_2"
    pane_id = "%2"
    seed_session!(session, pane_id)

    assert {:ok, first} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert {:ok, second} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5174/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert second.preview_id != first.preview_id
    assert PreviewPanes.get_by_pane(pane_id).url == "http://localhost:5174/"
  end

  test "distinct panes are distinct previews even at the same surface label" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_split"

    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 2, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session => [
        %{
          id: "%10",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 60,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        },
        %{
          id: "%11",
          window_id: "@1",
          index: 1,
          active: false,
          left: 60,
          top: 0,
          width: 60,
          height: 40,
          current_command: "devide-preview",
          current_path: "/tmp"
        }
      ]
    })

    # Two panes pointing at different ports must NOT collapse onto one preview
    # via the shared "preview-pane" surface label (regression for cross-URL
    # reuse: opening :5174 returned the existing :5173 preview).
    assert {:ok, a} =
             PreviewPanes.register(%{
               "pane_id" => "%10",
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert {:ok, b} =
             PreviewPanes.register(%{
               "pane_id" => "%11",
               "url" => "http://localhost:5174/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert a.preview_id != b.preview_id
    assert a.url == "http://localhost:5173/"
    assert b.url == "http://localhost:5174/"
    # Same URL in a second pane (mobile + desktop of one app) is still distinct.
    assert {:ok, c} =
             PreviewPanes.register(%{
               "pane_id" => "%10",
               "url" => "http://localhost:5174/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert c.preview_id != b.preview_id
    assert c.url == "http://localhost:5174/"
  end

  test "topology update expires vanished pane ids" do
    {_root, path} = seed_workspace!()
    session = "devide_ws_3"
    pane_id = "%3"
    seed_session!(session, pane_id)
    :ok = TmuxTopology.subscribe(session)

    assert {:ok, _registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    FakeState.put(:fake_tmux_panes, %{session => []})

    send(
      DevIDE.PreviewPanes,
      {DevIDE.Terminals.TmuxTopology,
       {:updated, TmuxTopology.snapshot(session, tmux: FakeAdapter)}}
    )

    Process.sleep(50)
    assert PreviewPanes.get_by_pane(pane_id) == nil
  end

  test "register returns workspace_not_found for unknown cwd" do
    assert {:error, :workspace_not_found} =
             PreviewPanes.register(%{
               "pane_id" => "%4",
               "url" => "http://localhost:5173/",
               "cwd" => "/tmp/definitely-not-a-workspace-#{System.unique_integer([:positive])}"
             })
  end
end
