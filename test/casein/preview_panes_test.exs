defmodule Casein.PreviewPanesTest do
  use Casein.DataCase, async: false

  alias Casein.PreviewPanes
  alias Casein.Previews.ControlSession
  alias Casein.Previews.Preview
  alias Casein.PreviewPanes.PreviewPaneRegistration
  alias Casein.Terminals.TmuxTopology
  alias Casein.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  setup do
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_app_url = Application.get_env(:casein, :preview_app_url)
    prev_loopback = Application.get_env(:casein, :preview_loopback_port)
    prev_proxy = Application.get_env(:casein, :preview_proxy_enabled)
    prev_persistence = Application.get_env(:casein, :preview_pane_persistence_enabled)
    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    Application.put_env(:casein, :preview_pane_persistence_enabled, true)
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

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp restart_preview_panes! do
    old_pid = Process.whereis(PreviewPanes)
    ref = Process.monitor(old_pid)
    Process.exit(old_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_pid, :killed}
    wait_for_preview_panes_restart(old_pid, 50)
    _ = :sys.get_state(PreviewPanes)
    :ok
  end

  defp wait_for_preview_panes_restart(old_pid, attempts_left) when attempts_left > 0 do
    case Process.whereis(PreviewPanes) do
      pid when is_pid(pid) and pid != old_pid ->
        :ok

      _ ->
        receive do
        after
          10 -> wait_for_preview_panes_restart(old_pid, attempts_left - 1)
        end
    end
  end

  defp wait_for_preview_panes_restart(_old_pid, 0), do: flunk("PreviewPanes did not restart")

  # Topology expiry/session_terminated offload tmux + Repo I/O; :sys.get_state only
  # flushes the GenServer mailbox, not in-flight tasks. Poll until the condition holds.
  defp wait_until(fun, attempts \\ 50)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      receive do
      after
        20 -> wait_until(fun, attempts - 1)
      end
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition not met before timeout")

  defp seed_workspace! do
    root = Casein.TmpWorkspace.root!("preview-panes")
    path = Path.join(root, "ws")
    File.mkdir_p!(path)
    Application.put_env(:casein, :workspaces_root, root)
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
          current_command: "casein-preview",
          current_path: "/tmp"
        }
      ]
    })
  end

  test "register creates preview pane registration and broadcasts" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_1"
    pane_id = "%9"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

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
    session = "casein_ws_external"
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

  test "register uses loopback control URL for Casein-hosted display URLs" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_casein_host"
    pane_id = "%13"
    display_url = "https://casein.example.com/whitehouse-preview.html"
    seed_session!(session, pane_id)
    Application.put_env(:casein, :preview_app_url, "https://casein.example.com")
    Application.put_env(:casein, :preview_loopback_port, 4100)

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

  test "register displays Casein loopback previews as same-origin paths" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_casein_loopback"
    pane_id = "%14"
    seed_session!(session, pane_id)
    Application.put_env(:casein, :preview_loopback_port, 4000)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:4000/workspaces?tab=agents#preview",
               "cwd" => path,
               "tmux_session" => session
             })

    control_session = Repo.get!(ControlSession, registration.control_session_id)
    assert registration.url == "http://localhost:4000/workspaces?tab=agents#preview"
    assert registration.display_url == "/workspaces?tab=agents#preview"
    assert control_session.current_url == "http://localhost:4000/workspaces?tab=agents#preview"
    assert control_session.metadata["display_url"] == "/workspaces?tab=agents#preview"

    assert control_session.metadata["control_url"] ==
             "http://localhost:4000/workspaces?tab=agents#preview"
  end

  test "register displays localhost app previews through the preview proxy" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_project_proxy"
    pane_id = "%16"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    Application.put_env(:casein, :preview_proxy_enabled, true)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/dashboard?tab=one",
               "cwd" => path,
               "tmux_session" => session
             })

    control_session = Repo.get!(ControlSession, registration.control_session_id)
    assert registration.url == "http://localhost:5173/dashboard?tab=one"

    assert registration.display_url ==
             "/preview-proxy/#{workspace_id}/5173/dashboard?tab=one"

    assert control_session.current_url == "http://localhost:5173/dashboard?tab=one"

    assert control_session.metadata["display_url"] ==
             "/preview-proxy/#{workspace_id}/5173/dashboard?tab=one"

    assert control_session.metadata["control_url"] == "http://localhost:5173/dashboard?tab=one"
  end

  test "register proxies localhost app previews by default when unset" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_default_proxy"
    pane_id = "%17"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    Application.delete_env(:casein, :preview_proxy_enabled)
    System.delete_env("CASEIN_PREVIEW_PROXY")

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:41034/superadmin?preview_superadmin=1",
               "cwd" => path,
               "tmux_session" => session
             })

    assert registration.url == "http://localhost:41034/superadmin?preview_superadmin=1"

    assert registration.display_url ==
             "/preview-proxy/#{workspace_id}/41034/superadmin?preview_superadmin=1"
  end

  test "sync control navigation keeps Casein loopback previews on same-origin paths" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_casein_loopback_sync"
    pane_id = "%15"
    seed_session!(session, pane_id)
    Application.put_env(:casein, :preview_loopback_port, 4000)
    Application.put_env(:casein, :preview_app_url, "https://casein.example.com")

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:4000",
               "cwd" => path,
               "tmux_session" => session
             })

    assert registration.display_url == "/"

    assert {:ok, synced} =
             PreviewPanes.sync_control_navigation(
               registration.control_session_id,
               "http://localhost:4000/workspaces/folder:abc123"
             )

    assert synced.display_url == "/workspaces/folder:abc123"
    assert PreviewPanes.get_by_pane(pane_id).display_url == "/workspaces/folder:abc123"
  end

  test "sync control navigation keeps runtime localhost previews proxied for browser refresh" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_runtime_loopback_sync"
    pane_id = "%16"
    seed_session!(session, pane_id)
    Application.put_env(:casein, :preview_loopback_port, 4000)
    Application.put_env(:casein, :preview_proxy_enabled, true)
    Application.put_env(:casein, :preview_app_url, "https://casein.example.com")
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:41034/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert registration.display_url == "/preview-proxy/#{workspace_id}/41034/"

    assert {:ok, synced} =
             PreviewPanes.sync_control_navigation(
               registration.control_session_id,
               "http://localhost:41034/login"
             )

    assert synced.display_url == "/preview-proxy/#{workspace_id}/41034/login"
    assert PreviewPanes.get_by_pane(pane_id).display_url == synced.display_url
  end

  # Own-origin routing shows the pane at `pv-<port>-<workspace>`, but that
  # origin was missing from the preview's allowlist, so the control-sync that
  # follows agent-driven navigation and typing was refused as
  # `:untrusted_preview_url` — the action ran in the automation browser while
  # the operator's iframe stayed on the old page.
  describe "own-origin preview panes" do
    @own_origin_ws "c32613b7-c8bb-4146-b6f3-9c4fe6f2f8ad"

    setup do
      prev_own = Application.get_env(:casein, :preview_own_origin)

      Application.put_env(:casein, :preview_own_origin,
        enabled: true,
        domain: "devbox.example.com"
      )

      Application.put_env(:casein, :preview_proxy_enabled, true)
      Application.put_env(:casein, :preview_loopback_port, 4000)

      on_exit(fn -> restore(:preview_own_origin, prev_own) end)

      :ok
    end

    defp register_own_origin_pane!(session, pane_id) do
      seed_session!(session, pane_id)

      assert {:ok, registration} =
               PreviewPanes.register(%{
                 "pane_id" => pane_id,
                 "url" => "http://localhost:21000/",
                 "tmux_session" => session,
                 "workspace" => %{
                   id: @own_origin_ws,
                   metadata: %{detected_ports: [21_000]}
                 }
               })

      assert registration.display_url ==
               "https://pv-21000-#{@own_origin_ws}.devbox.example.com/"

      registration
    end

    test "register records the origin the pane is displayed at as an allowed origin" do
      registration = register_own_origin_pane!("casein_ws_own_origin_allowlist", "%44")
      preview = Repo.get!(Preview, registration.preview_id)

      assert "https://pv-21000-#{@own_origin_ws}.devbox.example.com:443" in preview.metadata[
               "allowed_origins"
             ]
    end

    test "sync control navigation follows the pane's own proxy origin" do
      registration = register_own_origin_pane!("casein_ws_own_origin_sync", "%40")

      assert {:ok, synced} =
               PreviewPanes.sync_control_navigation(
                 registration.control_session_id,
                 "http://localhost:21000/superadmin/mira"
               )

      assert synced.display_url ==
               "https://pv-21000-#{@own_origin_ws}.devbox.example.com/superadmin/mira"

      assert PreviewPanes.get_by_pane("%40").display_url == synced.display_url
    end

    # Panes registered before the origin was recorded carry the old allowlist.
    # They are repaired in place rather than by a data migration, so strip the
    # origin back out and prove the sync still succeeds.
    test "sync control navigation trusts its own proxy origin even when the allowlist omits it" do
      registration = register_own_origin_pane!("casein_ws_own_origin_legacy", "%41")

      preview = Repo.get!(Preview, registration.preview_id)
      pv_origin = "https://pv-21000-#{@own_origin_ws}.devbox.example.com"
      stripped = Enum.reject(preview.metadata["allowed_origins"], &(&1 =~ "pv-21000"))

      preview
      |> Ecto.Changeset.change(metadata: Map.put(preview.metadata, "allowed_origins", stripped))
      |> Repo.update!()

      refute pv_origin in stripped

      assert {:ok, synced} =
               PreviewPanes.sync_control_navigation(
                 registration.control_session_id,
                 "http://localhost:21000/superadmin"
               )

      assert synced.display_url == pv_origin <> "/superadmin"
    end

    test "sync control navigation still refuses another workspace's proxy origin" do
      registration = register_own_origin_pane!("casein_ws_own_origin_foreign", "%42")
      other = "11111111-2222-3333-4444-555555555555"

      assert {:error, :untrusted_preview_url} =
               PreviewPanes.sync_control_navigation(
                 registration.control_session_id,
                 "https://pv-21000-#{other}.devbox.example.com/"
               )
    end

    test "sync control navigation still refuses an unrelated external origin" do
      registration = register_own_origin_pane!("casein_ws_own_origin_external", "%43")

      assert {:error, :untrusted_preview_url} =
               PreviewPanes.sync_control_navigation(
                 registration.control_session_id,
                 "https://example.com/news"
               )
    end
  end

  test "register threads workspace forward-auth headers into the control session" do
    session = "casein_ws_forward_auth"
    pane_id = "%20"
    seed_session!(session, pane_id)

    prev_domain = Application.get_env(:casein, :forward_auth_email_domain)
    Application.put_env(:casein, :forward_auth_email_domain, "milcgroup.com")

    on_exit(fn ->
      restore(:forward_auth_email_domain, prev_domain)
    end)

    workspace = %{
      id: "ws-forward-auth",
      name: "forward-auth",
      path: "/tmp",
      metadata: %{user: "Dalexandre", terminal_output: "", detected_ports: [5173]}
    }

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "workspace" => workspace,
               "tmux_session" => session
             })

    control_session = Repo.get!(ControlSession, registration.control_session_id)

    assert control_session.metadata["default_headers"] == %{
             "X-Auth-Request-Email" => "dalexandre@milcgroup.com"
           }
  end

  test "navigate updates pane registration and broadcasts the new display URL" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_nav"
    pane_id = "%14"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

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

  test "navigate routes a loopback preview through the proxy when HMR is enabled" do
    prev_hmr = Application.get_env(:casein, :preview_proxy_hmr)
    on_exit(fn -> restore(:preview_proxy_hmr, prev_hmr) end)

    {_root, path} = seed_workspace!()
    session = "casein_ws_nav_hmr"
    pane_id = "%19"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    # Register with the proxy off so the base stays a direct loopback URL,
    # making the navigation itself the thing that triggers proxying.
    Application.put_env(:casein, :preview_proxy_enabled, false)

    assert {:ok, _registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    Application.put_env(:casein, :preview_proxy_enabled, true)
    Application.put_env(:casein, :preview_app_url, "https://casein.example.com")
    Application.put_env(:casein, :preview_proxy_hmr, enabled: true)

    assert {:ok, navigated} = PreviewPanes.navigate(pane_id, "/settings")
    assert navigated.display_url == "/preview-proxy/#{workspace_id}/5173/settings"
  end

  test "history controls update pane registration and broadcast display URL" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_history"
    pane_id = "%18"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

    assert {:ok, _registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, _} = PreviewPanes.navigate(pane_id, "/one")
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, _} = PreviewPanes.navigate(pane_id, "/two")
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, back} = PreviewPanes.go_back(pane_id)
    assert back.display_url == "http://localhost:5173/one"
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id, display_url: back_url}}
    assert back_url == "http://localhost:5173/one"

    assert {:ok, forward} = PreviewPanes.go_forward(pane_id)
    assert forward.display_url == "http://localhost:5173/two"
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id, display_url: forward_url}}
    assert forward_url == "http://localhost:5173/two"

    assert {:ok, refreshed} = PreviewPanes.reload(pane_id)
    assert refreshed.display_url == "http://localhost:5173/two"
  end

  test "browser task DOWN for completed task does not crash with another task pending" do
    pending_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> send(pending_pid, :stop) end)

    pending_ref = make_ref()
    caller = {self(), make_ref()}

    :sys.replace_state(PreviewPanes, fn state ->
      %{
        state
        | pending_ops: %{
            pending_ref => %{
              from: caller,
              pid: pending_pid,
              kind: :browser,
              pane_id: nil,
              plan: nil,
              waiters: []
            }
          }
      }
    end)

    # DOWN for a different pid must not disturb the still-pending op.
    send(Process.whereis(PreviewPanes), {:DOWN, make_ref(), :process, self(), :normal})

    state = :sys.get_state(PreviewPanes)
    assert %{^pending_ref => %{from: ^caller, pid: ^pending_pid}} = state.pending_ops
  end

  test "navigate falls back to a snapshot when the target refuses framing" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_noframe"
    pane_id = "%19"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    artifacts_root =
      Path.join(System.tmp_dir!(), "preview-artifacts-#{System.unique_integer([:positive])}")

    Application.put_env(:casein, :preview_artifacts_root, artifacts_root)
    Application.put_env(:preview_ctl, :frame_blocked_hosts, ["hex.pm"])

    on_exit(fn ->
      Application.delete_env(:casein, :preview_artifacts_root)
      Application.delete_env(:preview_ctl, :frame_blocked_hosts)
      File.rm_rf(artifacts_root)
    end)

    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

    assert {:ok, _registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, snapshot} = PreviewPanes.navigate(pane_id, "https://hex.pm/")

    # An unframeable site is shown as a same-origin screenshot artifact instead
    # of a doomed live iframe.
    assert snapshot.display_url =~ "/preview-artifacts/"
    assert snapshot.display_url =~ "?fit=preview"
    refute snapshot.display_url =~ "hex.pm"

    # The real site we snapshotted is preserved so observers can report it
    # instead of the artifact path we serve.
    assert snapshot.source_url == "https://hex.pm/"

    preview = Repo.get!(Preview, snapshot.preview_id)
    assert preview.metadata["source_url"] == "https://hex.pm/"

    assert_receive {:preview_pane_registered,
                    %{pane_id: ^pane_id, display_url: display_url, source_url: "https://hex.pm/"}}

    assert display_url == snapshot.display_url

    # A relative path from a snapshot must resolve against the real site, not
    # against the `/preview-artifacts/` path we are serving it from. Resolving
    # against the artifact rebuilt the URL on the Casein origin, and because that
    # origin is self-allowlisted nothing downstream refused it — the pane
    # silently stopped previewing the app.
    assert {:ok, onward} = PreviewPanes.navigate(pane_id, "/packages")
    assert onward.source_url == "https://hex.pm:443/packages"
    refute onward.source_url =~ "preview-artifacts"

    # Navigating onward to an embeddable site clears the stale source URL.
    assert {:ok, framed} = PreviewPanes.navigate(pane_id, "http://localhost:5173/back")
    assert framed.source_url == nil
    assert Repo.get!(Preview, framed.preview_id).metadata["source_url"] == nil
  end

  test "show_artifact points a registered pane at a screenshot artifact" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_snapshot"
    pane_id = "%15"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, snapshot} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/1.png"
             )

    assert snapshot.display_url ==
             "http://localhost:5173/preview-artifacts/#{workspace_id}/1.png?fit=preview"

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id, display_url: display_url}}
    assert display_url == snapshot.display_url

    # The page being snapshotted is recorded, so a later relative navigation has
    # something to resolve against. Without it the pane's only remembered URL is
    # the artifact path, and navigating moves it onto the Casein origin.
    assert snapshot.source_url == registration.display_url

    assert Repo.get!(Preview, snapshot.preview_id).metadata["source_url"] ==
             registration.display_url
  end

  test "show_artifact keeps the original source when re-snapshotting an already-snapshot pane" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_snapshot_resnap"
    pane_id = "%45"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    original_display_url = registration.display_url

    assert {:ok, first} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/1.png"
             )

    assert first.source_url == original_display_url

    # Re-snapshotting must not overwrite the source with the artifact path — that
    # would erase the only pointer back to the app being previewed.
    assert {:ok, second} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/2.png"
             )

    assert second.source_url == original_display_url
    refute second.source_url =~ "preview-artifacts"
  end

  test "click_snapshot forwards a coordinate click and refreshes the snapshot artifact" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_snapshot_click"
    pane_id = "%16"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session,
               "viewport" => "120x80"
             })

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, _snapshot} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/1.png"
             )

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, clicked} = PreviewPanes.click_snapshot(pane_id, %{"x" => 20, "y" => 30})

    assert clicked.pane_id == pane_id
    assert clicked.display_url =~ "/preview-artifacts/#{workspace_id}/"
    assert clicked.display_url =~ "?fit=preview"
    refute clicked.display_url =~ "/1.png?"

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id, display_url: display_url}}
    assert display_url == clicked.display_url
  end

  test "click_snapshot rejects coordinates outside the stored viewport" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_snapshot_bounds"
    pane_id = "%17"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session,
               "viewport" => "120x80"
             })

    assert {:ok, _snapshot} =
             PreviewPanes.show_artifact(
               registration.control_session_id,
               "/preview-artifacts/#{workspace_id}/1.png"
             )

    assert {:error, :snapshot_click_out_of_bounds} =
             PreviewPanes.click_snapshot(pane_id, %{"x" => 120, "y" => 30})
  end

  test "double register replaces the existing pane registration" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_2"
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
               "url" => "http://localhost:41051/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert second.preview_id != first.preview_id
    assert PreviewPanes.get_by_pane(pane_id).url == "http://localhost:41051/"
  end

  test "share_session registers another pane against the same control session" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_shared"
    source_pane_id = "%21"
    shared_pane_id = "%22"
    seed_session!(session, source_pane_id)
    seed_session!(session, shared_pane_id)

    assert {:ok, source} =
             PreviewPanes.register(%{
               "pane_id" => source_pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert {:ok, shared} =
             PreviewPanes.register(%{
               "pane_id" => shared_pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session,
               "share_session" => true,
               "attach_to_pane_id" => source_pane_id,
               "viewport" => "375x812"
             })

    assert shared.preview_id == source.preview_id
    assert shared.control_session_id == source.control_session_id
    assert shared.shared == true
    assert shared.source_pane_id == source_pane_id
    assert shared.viewport == %{width: 375, height: 812}
  end

  test "set_viewport locks, retunes and clears a pane's viewport" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_viewport"
    pane_id = "%40"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert registration.viewport == nil
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, locked} = PreviewPanes.set_viewport(pane_id, "390x844")
    assert locked.viewport == %{width: 390, height: 844}
    assert PreviewPanes.get_by_pane(pane_id).viewport == %{width: 390, height: 844}

    # The :updated broadcast is what re-renders data-viewport for the overlay.
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, retuned} = PreviewPanes.set_viewport(pane_id, "820x1180")
    assert retuned.viewport == %{width: 820, height: 1180}

    # nil and "" both mean "back to filling the pane".
    assert {:ok, cleared} = PreviewPanes.set_viewport(pane_id, "")
    assert cleared.viewport == nil
    assert PreviewPanes.get_by_pane(pane_id).viewport == nil

    assert {:ok, _} = PreviewPanes.set_viewport(pane_id, "390x844")
    assert {:ok, cleared_nil} = PreviewPanes.set_viewport(pane_id, nil)
    assert cleared_nil.viewport == nil
  end

  test "set_viewport survives a restart via the persisted registration" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_viewport_persist"
    pane_id = "%41"
    seed_session!(session, pane_id)

    assert {:ok, _} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert {:ok, _} = PreviewPanes.set_viewport(pane_id, "390x844")

    persisted = Repo.get_by!(PreviewPaneRegistration, pane_id: pane_id, status: :open)
    assert persisted.viewport == %{"width" => 390, "height" => 844}
  end

  test "set_viewport refuses a malformed size rather than silently unlocking" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_viewport_bad"
    pane_id = "%42"
    seed_session!(session, pane_id)

    assert {:ok, _} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert {:ok, _} = PreviewPanes.set_viewport(pane_id, "390x844")

    for bad <- ["garbage", "390", "390x", "x844", "390x844px", "-1x844"] do
      assert {:error, :invalid_viewport} = PreviewPanes.set_viewport(pane_id, bad),
             "expected #{inspect(bad)} to be refused"
    end

    # A typo must leave the pane exactly as it was, not reset it.
    assert PreviewPanes.get_by_pane(pane_id).viewport == %{width: 390, height: 844}
  end

  test "set_viewport on an unknown pane reports not_found" do
    assert {:error, :not_found} = PreviewPanes.set_viewport("%nope", "390x844")
  end

  test "shared panes navigate together and close the session on the last deregistration" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_shared_nav"
    source_pane_id = "%23"
    shared_pane_id = "%24"
    seed_session!(session, source_pane_id)
    seed_session!(session, shared_pane_id)

    assert {:ok, source} =
             PreviewPanes.register(%{
               "pane_id" => source_pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert {:ok, _shared} =
             PreviewPanes.register(%{
               "pane_id" => shared_pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session,
               "share_session" => true,
               "attach_to_pane_id" => source_pane_id
             })

    assert {:ok, navigated} = PreviewPanes.navigate(source_pane_id, "/settings")
    assert navigated.display_url == "http://localhost:5173/settings"
    assert PreviewPanes.get_by_pane(shared_pane_id).display_url == navigated.display_url

    assert :ok = PreviewPanes.deregister(shared_pane_id)
    assert Repo.get!(ControlSession, source.control_session_id).status == :open

    assert :ok = PreviewPanes.deregister(source_pane_id)
    assert Repo.get!(ControlSession, source.control_session_id).status == :closed
  end

  test "share_session returns no_shared_preview_found without a source" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_shared_missing"
    pane_id = "%25"
    seed_session!(session, pane_id)

    assert {:error, :no_shared_preview_found} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session,
               "share_session" => true
             })
  end

  test "heartbeat register refreshes without replacing the preview session" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_heartbeat"
    pane_id = "%22"
    seed_session!(session, pane_id)
    workspace_id = "folder:" <> Base.url_encode64(path, padding: false)
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "preview:" <> workspace_id)

    assert {:ok, first} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}

    assert {:ok, heartbeat} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session,
               "heartbeat" => true
             })

    assert heartbeat.preview_id == first.preview_id
    assert heartbeat.control_session_id == first.control_session_id
    assert Repo.get!(Preview, first.preview_id).status == :open
    assert Repo.get!(ControlSession, first.control_session_id).status == :open
    assert_receive {:preview_pane_registered, %{pane_id: ^pane_id}}
  end

  test "stale topology update does not expire a pane that still exists in tmux" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_stale_topology"
    pane_id = "%12"
    seed_session!(session, pane_id)

    assert {:ok, _registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    send(
      Process.whereis(PreviewPanes),
      {TmuxTopology, {:updated, %{session: session, panes: []}}}
    )

    # Probe offload confirms the pane still exists in FakeTmux — must not expire.
    wait_until(fn ->
      match?(%{}, :sys.get_state(PreviewPanes)) and PreviewPanes.get_by_pane(pane_id) != nil
    end)

    assert PreviewPanes.get_by_pane(pane_id)

    FakeState.put(:fake_tmux_panes, %{session => []})

    send(
      Process.whereis(PreviewPanes),
      {TmuxTopology, {:updated, %{session: session, panes: []}}}
    )

    wait_until(fn -> PreviewPanes.get_by_pane(pane_id) == nil end)
    refute PreviewPanes.get_by_pane(pane_id)
  end

  test "list_for_workspace_exact rehydrates persisted registrations after registry restart" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_rehydrate"
    pane_id = "%14"
    seed_session!(session, pane_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert %PreviewPaneRegistration{status: :open} =
             Repo.get_by(PreviewPaneRegistration, pane_id: pane_id)

    restart_preview_panes!()

    assert [%{pane_id: ^pane_id, preview_id: preview_id}] =
             PreviewPanes.list_for_workspace_exact(registration.workspace_id)

    assert preview_id == registration.preview_id
    assert PreviewPanes.get_by_pane(pane_id).control_session_id == registration.control_session_id
  end

  test "rehydration closes persisted registrations whose tmux pane is gone" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_rehydrate_stale"
    pane_id = "%15"
    seed_session!(session, pane_id)

    assert {:ok, registration} =
             PreviewPanes.register(%{
               "pane_id" => pane_id,
               "url" => "http://localhost:5173/",
               "cwd" => path,
               "tmux_session" => session
             })

    restart_preview_panes!()
    FakeState.put(:fake_tmux_panes, %{session => []})

    assert [] = PreviewPanes.list_for_workspace_exact(registration.workspace_id)

    assert %PreviewPaneRegistration{status: :closed} =
             Repo.get_by(PreviewPaneRegistration, pane_id: pane_id)
  end

  test "distinct panes are distinct previews even at the same surface label" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_split"

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
          current_command: "casein-preview",
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
          current_command: "casein-preview",
          current_path: "/tmp"
        }
      ]
    })

    # Two panes pointing at different ports must NOT collapse onto one preview
    # via the shared "preview-pane" surface label (regression for cross-URL
    # reuse: opening :41051 returned the existing :5173 preview).
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
               "url" => "http://localhost:41051/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert a.preview_id != b.preview_id
    assert a.url == "http://localhost:5173/"
    assert b.url == "http://localhost:41051/"
    # Same URL in a second pane (mobile + desktop of one app) is still distinct.
    assert {:ok, c} =
             PreviewPanes.register(%{
               "pane_id" => "%10",
               "url" => "http://localhost:41051/",
               "cwd" => path,
               "tmux_session" => session
             })

    assert c.preview_id != b.preview_id
    assert c.url == "http://localhost:41051/"
  end

  test "topology update expires vanished pane ids" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_3"
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
      Casein.PreviewPanes,
      {Casein.Terminals.TmuxTopology,
       {:updated, TmuxTopology.snapshot(session, tmux: FakeAdapter)}}
    )

    wait_until(fn -> PreviewPanes.get_by_pane(pane_id) == nil end)
    assert PreviewPanes.get_by_pane(pane_id) == nil
  end

  test "topology expire closes all persisted registrations for vanished panes" do
    {_root, path} = seed_workspace!()
    session = "casein_ws_batch_expire"
    pane_ids = ["%50", "%51", "%52"]

    FakeState.put(:fake_tmux_windows, %{
      session => [%{id: "@1", index: 0, name: "bash", active: true, panes: 3, activity: 0}]
    })

    FakeState.put(:fake_tmux_panes, %{
      session =>
        Enum.map(pane_ids, fn pane_id ->
          %{
            id: pane_id,
            window_id: "@1",
            index: 0,
            active: true,
            left: 0,
            top: 0,
            width: 120,
            height: 40,
            current_command: "casein-preview",
            current_path: "/tmp"
          }
        end)
    })

    for pane_id <- pane_ids do
      assert {:ok, _} =
               PreviewPanes.register(%{
                 "pane_id" => pane_id,
                 "url" => "http://localhost:5173/#{pane_id}",
                 "cwd" => path,
                 "tmux_session" => session
               })
    end

    assert Enum.all?(pane_ids, fn pane_id ->
             match?(
               %PreviewPaneRegistration{status: :open},
               Repo.get_by(PreviewPaneRegistration, pane_id: pane_id)
             )
           end)

    FakeState.put(:fake_tmux_panes, %{session => []})

    send(
      Process.whereis(PreviewPanes),
      {TmuxTopology, {:updated, TmuxTopology.snapshot(session, tmux: FakeAdapter)}}
    )

    wait_until(fn ->
      Enum.all?(pane_ids, fn pane_id ->
        PreviewPanes.get_by_pane(pane_id) == nil and
          match?(
            %PreviewPaneRegistration{status: :closed},
            Repo.get_by(PreviewPaneRegistration, pane_id: pane_id)
          )
      end)
    end)

    for pane_id <- pane_ids do
      assert PreviewPanes.get_by_pane(pane_id) == nil

      assert %PreviewPaneRegistration{status: :closed} =
               Repo.get_by(PreviewPaneRegistration, pane_id: pane_id)
    end
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
