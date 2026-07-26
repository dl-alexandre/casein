defmodule Casein.Agents.PreviewToolsTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.PreviewTools
  alias Casein.PreviewActivity
  alias Casein.PreviewControl.Registry
  alias Casein.PreviewPanes
  alias Casein.Previews.ControlSession
  alias Casein.Previews.ControlObservation
  alias Casein.Runtimes
  alias Casein.Terminals.Tmux
  alias Casein.Test.RuntimeSeed
  alias Casein.TestSupport.HTTPStub
  alias Casein.Repo
  alias TmuxCtl.Test.FakeAdapter
  alias TmuxCtl.Test.FakeState

  @v3_workspace %{
    id: "ws-tools",
    metadata: %{
      type: :v3,
      domain_base: "alice.devbox.example.com",
      ports: %{"app" => 10_100}
    }
  }

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)
    prev_tmux = Application.get_env(:casein, :tmux_adapter)
    prev_api_token = Application.get_env(:casein, :casein_api_token)
    prev_app_url = Application.get_env(:casein, :preview_app_url)
    prev_preflight = Application.get_env(:casein, :preview_open_preflight)
    prev_persistence = Application.get_env(:casein, :preview_pane_persistence_enabled)

    prev_visibility_initial =
      Application.get_env(:casein, :preview_operator_visibility_initial_timeout_ms)

    prev_visibility_iframe =
      Application.get_env(:casein, :preview_operator_visibility_iframe_reload_timeout_ms)

    prev_visibility_page =
      Application.get_env(:casein, :preview_operator_visibility_page_reload_timeout_ms)

    prev_fake_tmux_pid = FakeState.get(:fake_tmux_test_pid)
    Application.put_env(:casein, :tmux_adapter, FakeAdapter)
    Application.put_env(:casein, :casein_api_token, "preview-tools-test-token")
    Application.put_env(:casein, :preview_pane_persistence_enabled, false)
    Application.put_env(:casein, :preview_operator_visibility_initial_timeout_ms, 0)
    Application.put_env(:casein, :preview_operator_visibility_iframe_reload_timeout_ms, 0)
    Application.put_env(:casein, :preview_operator_visibility_page_reload_timeout_ms, 0)
    FakeState.put(:fake_tmux_test_pid, self())
    _ = Registry.clear()
    Runtimes.clear()
    PreviewActivity.clear()
    PreviewPanes.clear()
    seed_workspace_tmux!(@v3_workspace.id)

    on_exit(fn ->
      Runtimes.clear()
      PreviewActivity.clear()
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:fake_tmux_alive_sessions)
      FakeState.delete(:fake_tmux_session_meta)
      FakeState.delete(:fake_tmux_split_pane_exits)
      FakeState.delete(:fake_tmux_scrollback)
      restore_fake_state(:fake_tmux_test_pid, prev_fake_tmux_pid)

      if is_nil(prev_root),
        do: Application.delete_env(:casein, :workspaces_root),
        else: Application.put_env(:casein, :workspaces_root, prev_root)

      restore_env(:tmux_adapter, prev_tmux)
      restore_env(:casein_api_token, prev_api_token)
      restore_env(:preview_app_url, prev_app_url)
      restore_env(:preview_open_preflight, prev_preflight)
      restore_env(:preview_pane_persistence_enabled, prev_persistence)
      restore_env(:preview_operator_visibility_initial_timeout_ms, prev_visibility_initial)
      restore_env(:preview_operator_visibility_iframe_reload_timeout_ms, prev_visibility_iframe)
      restore_env(:preview_operator_visibility_page_reload_timeout_ms, prev_visibility_page)
    end)

    :ok
  end

  defp seed_workspace_tmux!(workspace_id, opts \\ []) when is_binary(workspace_id) do
    session =
      Keyword.get(opts, :session, "#{Tmux.workspace_session_prefix(workspace_id)}default")

    activity = Keyword.get(opts, :activity, 0)
    pane_id = Keyword.get(opts, :pane_id, "%1")

    FakeState.update(:fake_tmux_alive_sessions, MapSet.new(), &MapSet.put(&1, session))

    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{id: "@1", index: 0, name: "bash", active: true, panes: 1, activity: activity}
      ])
    end)

    FakeState.update(:fake_tmux_panes, %{}, fn panes ->
      Map.put(panes, session, [
        %{
          id: pane_id,
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 120,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        }
      ])
    end)

    FakeState.put(:fake_tmux_scrollback, %{
      {session, pane_id} => "# Casein agent pane\n"
    })
  end

  defp seed_multi_window_tmux!(session) do
    FakeState.update(:fake_tmux_alive_sessions, MapSet.new(), &MapSet.put(&1, session))

    FakeState.update(:fake_tmux_windows, %{}, fn windows ->
      Map.put(windows, session, [
        %{id: "@1", index: 0, name: "agent", active: false, panes: 2, activity: 10},
        %{id: "@2", index: 1, name: "preview-server", active: true, panes: 1, activity: 20}
      ])
    end)

    FakeState.update(:fake_tmux_panes, %{}, fn panes ->
      Map.put(panes, session, [
        %{
          id: "%10",
          window_id: "@1",
          index: 0,
          active: false,
          left: 0,
          top: 0,
          width: 80,
          height: 40,
          current_command: "bash",
          current_path: "/tmp"
        },
        %{
          id: "%11",
          window_id: "@1",
          index: 1,
          active: false,
          left: 80,
          top: 0,
          width: 80,
          height: 40,
          current_command: "claude",
          current_path: "/tmp"
        },
        %{
          id: "%20",
          window_id: "@2",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 160,
          height: 40,
          current_command: "mix",
          current_path: "/tmp"
        }
      ])
    end)

    FakeState.put(:fake_tmux_scrollback, %{
      {session, "%11"} => "# Casein agent pane\n"
    })
  end

  defp seed_runtime_surface!(workspace_id, tmux_session, opts) do
    runtime_id = Keyword.get(opts, :runtime_id, "rt-#{System.unique_integer([:positive])}")
    port = Keyword.get(opts, :port, 4101)
    worktree_path = "/tmp/#{workspace_id}/#{runtime_id}"

    preview_server = %{
      "id" => "preview:#{runtime_id}:app",
      "runtime_id" => runtime_id,
      "workspace_id" => workspace_id,
      "tmux_session_id" => tmux_session,
      "cwd" => worktree_path,
      "worktree_path" => worktree_path,
      "port" => port,
      "status" => "provisioned",
      "command" => ["bash", "scripts/preview-env.sh", "dirty", "--port", Integer.to_string(port)],
      "env" => %{
        "PORT" => Integer.to_string(port),
        "CASEIN_RUNTIME_ID" => runtime_id,
        "CASEIN_WORKSPACE_ID" => workspace_id,
        "CASEIN_TMUX_SESSION" => tmux_session
      },
      "surface_key" => "runtime:#{runtime_id}:app",
      "surface_name" => "app",
      "url" => "http://localhost:#{port}",
      "source" => "runtime_preview_server"
    }

    RuntimeSeed.seed_runtime!(workspace_id,
      runtime_id: runtime_id,
      status: "provisioned",
      tmux_session_id: tmux_session,
      worktree_path: worktree_path,
      runtime_profile: %{
        "name" => "custom",
        "ports" => %{"app" => port},
        "surfaces" => [%{"name" => "app", "port" => port}]
      },
      metadata: %{"kind" => "agent_worktree", "preview_server" => preview_server}
    )
  end

  test "definitions use shared McpCtl preview workspace_id schema" do
    tool = Enum.find(PreviewTools.definitions(), &(&1.name == "preview_open_app"))
    assert tool.parameters.properties.workspace_id.description =~ "pre-scoped"
    assert tool.parameters.properties.workspace_path.description =~ "folder:"
  end

  test "definitions exposes narrow agent preview tools" do
    names = PreviewTools.definitions() |> Enum.map(& &1.name)
    assert "preview_resolve_workspace" in names
    assert "preview_surfaces" in names
    assert "preview_open_current_workspace" in names
    assert "preview_open_here" in names
    assert "preview_ensure_server_here" in names
    assert "preview_open_app" in names
    assert "preview_open_localhost" in names
    assert "preview_navigate" in names
    assert "preview_navigate_pane" in names
    assert "preview_observe_pane" in names
    assert "preview_observe" in names
    assert "preview_observe_live" in names
    assert "preview_elements" in names
    assert "preview_screenshot" in names
    assert "preview_playback_open" in names
    assert "preview_close" in names
    assert "preview_get_storage" in names
    assert "preview_reload_iframe" in names
    assert "casein_reload_page" in names
  end

  test "exposes agent-driven recording tools requiring a session id" do
    defs = PreviewTools.definitions()

    for name <- ["preview_record_start", "preview_record_stop"] do
      tool = Enum.find(defs, &(&1.name == name))
      assert tool, "#{name} should be defined"
      assert "session_id" in Enum.map(tool.parameters.required, &to_string/1)
      assert tool.metadata.mutation? == true
      assert :preview_control in tool.metadata.capabilities
    end
  end

  test "invoke routes the recording tools (not unknown_tool)" do
    # No live Playwright session in tests, so this errors — but it must dispatch
    # to the handler, never fall through to :unknown_tool.
    assert PreviewTools.invoke("preview_record_start", %{}, %{"session_id" => "999999"}) !=
             {:error, :unknown_tool}

    assert PreviewTools.invoke("preview_record_stop", %{}, %{"session_id" => "999999"}) !=
             {:error, :unknown_tool}
  end

  test "playback tool opens a saved recording in fresh panes" do
    Application.put_env(:casein, :preview_app_url, "https://casein.example.test/workspaces")

    artifact_path = "/preview-artifacts/#{@v3_workspace.id}/demo.webm"
    playback_url = "https://casein.example.test:443#{artifact_path}?fit=playback&loop=1"

    assert {:ok, first} =
             PreviewTools.invoke("preview_playback_open", @v3_workspace, %{
               "artifact_path" => artifact_path,
               "actor_id" => "agent-1"
             })

    assert {:ok, second} =
             PreviewTools.invoke("preview_playback_open", @v3_workspace, %{
               "artifact_path" => artifact_path,
               "actor_id" => "agent-1"
             })

    assert first.artifact_path == artifact_path
    assert first.playback_url == playback_url
    assert first.loop == true
    assert first.next_tool == "preview_observe_pane"
    assert first.next_arguments == %{pane_id: first.pane_id}

    refute first.pane_id == second.pane_id
    assert PreviewPanes.get_by_pane(first.pane_id).display_url == playback_url
    assert PreviewPanes.get_by_pane(second.pane_id).display_url == playback_url
  end

  test "playback tool rejects artifacts outside the workspace and non-video artifacts" do
    Application.put_env(:casein, :preview_app_url, "https://casein.example.test")

    assert {:error, %{error: :invalid_playback_artifact}} =
             PreviewTools.invoke("preview_playback_open", @v3_workspace, %{
               "artifact_path" => "/preview-artifacts/other/clip.webm"
             })

    assert {:error, %{error: :invalid_playback_artifact}} =
             PreviewTools.invoke("preview_playback_open", @v3_workspace, %{
               "artifact_path" => "/preview-artifacts/#{@v3_workspace.id}/nested%2Fclip.webm"
             })

    assert {:error, %{error: :unsupported_playback_artifact}} =
             PreviewTools.invoke("preview_playback_open", @v3_workspace, %{
               "artifact_path" => "/preview-artifacts/#{@v3_workspace.id}/clip.png"
             })
  end

  test "reload tools broadcast workspace browser control requests" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "workspace_browser:ws-tools")

    assert {:ok,
            %{
              status: "queued",
              action: "reload_preview_iframe",
              workspace_id: "ws-tools",
              request_id: iframe_request_id
            }} =
             PreviewTools.invoke("preview_reload_iframe", @v3_workspace, %{
               "actor_id" => "agent-1",
               "reason" => "stale preview"
             })

    assert_receive {:browser_control,
                    %{
                      "action" => "reload_preview_iframe",
                      "actor_id" => "agent-1",
                      "reason" => "stale preview",
                      "request_id" => ^iframe_request_id,
                      "workspace_id" => "ws-tools"
                    }}

    assert {:ok,
            %{
              status: "queued",
              action: "reload_page",
              workspace_id: "ws-tools",
              request_id: page_request_id
            }} =
             PreviewTools.invoke("casein_reload_page", @v3_workspace, %{"actor_id" => "agent-1"})

    assert_receive {:browser_control,
                    %{
                      "action" => "reload_page",
                      "actor_id" => "agent-1",
                      "request_id" => ^page_request_id,
                      "workspace_id" => "ws-tools"
                    }}
  end

  test "preview_close requires a session id or pane id instead of crashing on empty input" do
    assert {:error, {:missing_argument, "session_id or pane_id"}} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{
               "workspace_id" => "ws-tools",
               "pane_id" => ""
             })
  end

  test "invoke surfaces lists manager and terminal-detected ports" do
    ws =
      Map.update!(@v3_workspace, :metadata, fn metadata ->
        Map.put(metadata, :terminal_output, "Serving at http://localhost:8765/")
      end)

    assert {:ok, %{surfaces: surfaces}} = PreviewTools.invoke("preview_surfaces", ws, %{})
    names = Enum.map(surfaces, & &1.name)
    assert "app" in names
    assert "localhost:8765" in names
  end

  test "invoke surfaces reports registered pane visibility without claiming it is active" do
    ws =
      Map.update!(@v3_workspace, :metadata, fn metadata ->
        Map.put(metadata, :terminal_output, "Serving at http://localhost:5173/")
      end)

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.split_preview_pane(ws, "http://localhost:5173/", [])

    assert {:ok, %{surfaces: surfaces}} = PreviewTools.invoke("preview_surfaces", ws, %{})

    registered = Enum.find(surfaces, &(&1.pane_id == pane_id))
    assert registered.name == "localhost:5173"
    assert registered.pane_registered
    assert registered.server_active
    refute registered.active
    refute registered.operator_visible
    refute registered.browser_loaded
    assert registered.operator_visible_state == "not_rendered"
    assert registered.visibility.diagnostic.next_action == "verify_visible_workspace_and_pane"

    # Registered-but-not-rendered panes must not float to the top as active.
    refute hd(surfaces).active

    # Surfaces with no live pane stay inert.
    others = Enum.reject(surfaces, &(&1.pane_id == pane_id))
    assert Enum.all?(others, &(&1.active == false and &1.pane_registered == false))
  end

  test "invoke surfaces marks a pane active only after browser iframe load confirmation" do
    ws =
      Map.update!(@v3_workspace, :metadata, fn metadata ->
        Map.put(metadata, :terminal_output, "Serving at http://localhost:5173/")
      end)

    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(ws, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_loaded",
      summary: "iframe loaded",
      metadata: %{"url" => "http://localhost:5173/"}
    })

    assert {:ok, %{surfaces: surfaces}} = PreviewTools.invoke("preview_surfaces", ws, %{})

    active = hd(surfaces)
    assert active.name == "localhost:5173"
    assert active.pane_id == pane_id
    assert active.active
    assert active.operator_visible
    assert active.browser_loaded
    assert active.operator_visible_state == "browser_loaded"
  end

  test "registration_origin falls back to source url for proxied display urls" do
    assert PreviewTools.registration_origin(%{
             display_url: "/preview-proxy/ws-tools/5173/",
             url: "http://localhost:5173/"
           }) == "http://localhost:5173"
  end

  test "resolve_workspace reports attached_folder without question mark suffix" do
    root =
      Path.join(System.tmp_dir!(), "preview-tools-attached-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:casein, :workspaces_root, root)

    assert {:ok, %{attached_folder: true}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{
               "workspace_path" => workspace
             })
  end

  test "split_preview_pane returns error without tmux session" do
    assert {:error, :no_tmux_session} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/",
               tmux_session: nil
             )
  end

  test "split_preview_pane opens pane and preview_close kills it" do
    script =
      :code.priv_dir(:casein)
      |> List.to_string()
      |> Path.join("scripts/casein-preview")

    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert is_binary(pane_id)
    assert PreviewPanes.get_by_pane(pane_id)

    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert [%{id: ^pane_id, current_command: command}] =
             FakeState.get(:fake_tmux_panes, %{})
             |> Map.fetch!(tmux_session)
             |> Enum.filter(&(&1.id == pane_id))

    assert command =~ script
    assert command =~ "CASEIN_API_TOKEN="
    assert command =~ "CASEIN_WORKSPACE_ID=#{@v3_workspace.id}"
    assert command =~ "http://localhost:5173/"

    assert {:ok, %{status: :closed}} =
             PreviewTools.invoke("preview_close", %{}, %{"session_id" => session.id})

    refute PreviewPanes.get_by_pane(pane_id)
  end

  test "preview_close can close by registered pane id" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert {:ok,
            %{
              pane_id: ^pane_id,
              session_id: session_id,
              status: :closed,
              tmux_kill: %{status: "ok"},
              deregister: %{status: "ok"}
            }} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{"pane_id" => pane_id})

    assert session_id == session.id
    refute PreviewPanes.get_by_pane(pane_id)

    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"
    assert_receive {:fake_tmux_kill_pane, ^tmux_session, ^pane_id}
  end

  test "preview_close can remove an unregistered stale tmux pane when tmux_session is provided" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert :ok = PreviewPanes.deregister(pane_id)

    assert {:ok,
            %{
              pane_id: ^pane_id,
              status: :closed,
              stale: true,
              tmux_session: ^tmux_session,
              tmux_kill: %{status: "ok"}
            }} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{
               "pane_id" => pane_id,
               "tmux_session" => tmux_session
             })

    assert_receive {:fake_tmux_kill_pane, ^tmux_session, ^pane_id}
  end

  test "split_preview_pane rejects a holder pane that exits before registration" do
    FakeState.put(:fake_tmux_split_pane_exits, true)

    assert {:error,
            %{
              error: :preview_pane_exited,
              pane_id: "%2",
              message: "Preview pane exited before it could be shown; no preview pane was opened."
            }} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"
    assert [%{id: "%1"}] = FakeState.get(:fake_tmux_panes, %{}) |> Map.fetch!(tmux_session)
    refute PreviewPanes.get_by_pane("%2")
  end

  test "observe_pane reports pane state and recent interaction activity" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "pointer_down",
      summary: "pointer down @ 10,20",
      metadata: %{"x" => 10, "y" => 20}
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id,
               "limit" => 5
             })

    assert payload.pane_id == pane_id
    assert payload.workspace_id == @v3_workspace.id
    assert payload.session_id == session.id
    assert payload.url == "http://localhost:5173/"
    assert payload.display_url == "http://localhost:5173/"
    # An ordinary embeddable pane displays the real URL directly, so there is no
    # separate source URL to report.
    assert payload.source_url == nil
    assert payload.mode == "iframe"
    assert payload.status == "iframe_live"
    refute payload.snapshot_mode
    refute payload.browser_loaded
    assert payload.operator_visible_state == "not_rendered"
    assert payload.visibility.diagnostic.next_action == "verify_visible_workspace_and_pane"

    assert %{event: "pointer_down", metadata: %{"x" => 10, "y" => 20}} =
             Enum.find(payload.recent_activity, &(&1.event == "pointer_down"))

    assert %{event: "observed", source: "mcp"} = hd(payload.recent_activity)
  end

  test "observe_pane reports browser iframe load confirmation separately from control observations" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_loaded",
      summary: "iframe loaded",
      metadata: %{"url" => "http://localhost:5173/"}
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id
             })

    assert payload.browser_loaded
    assert payload.operator_visible_state == "browser_loaded"
    assert is_binary(payload.browser_loaded_at)
    assert payload.tmux.present == true
    assert payload.tmux.pane_id == pane_id
    assert payload.visibility.last_browser_event.event == "iframe_loaded"
  end

  test "observe_pane expires stale browser iframe load confirmation" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_loaded",
      summary: "iframe loaded",
      metadata: %{"url" => "http://localhost:5173/"},
      inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id
             })

    refute payload.browser_loaded
    assert payload.operator_visible_state == "stale"
    assert payload.visibility.diagnostic.reason == "browser_visibility_stale"
  end

  test "observe_pane keeps old iframe load visible when browser heartbeat is fresh" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "visibility_heartbeat",
      summary: "visibility heartbeat",
      metadata: %{"url" => "http://localhost:5173/", "loaded" => true}
    })

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_loaded",
      summary: "iframe loaded",
      metadata: %{"url" => "http://localhost:5173/"},
      inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id
             })

    assert payload.browser_loaded
    assert payload.operator_visible_state == "browser_loaded"
    assert payload.visibility.diagnostic.next_action == "none"
  end

  test "observe_pane does not treat an unloaded browser heartbeat as visible" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_loaded",
      summary: "iframe loaded",
      metadata: %{"url" => "http://localhost:5173/"},
      inserted_at: DateTime.add(DateTime.utc_now(), -60, :second)
    })

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "visibility_heartbeat",
      summary: "visibility heartbeat",
      metadata: %{
        "url" => "http://localhost:5173/",
        "iframe_src" => "http://localhost:5173/",
        "loaded" => false
      }
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id
             })

    refute payload.browser_loaded
    assert payload.operator_visible_state == "stale"
    assert payload.visibility.diagnostic.reason == "browser_visibility_stale"
    assert payload.visibility.last_browser_event.event == "visibility_heartbeat"
  end

  test "observe_pane explains iframe src assigned without load" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_src_assigned",
      summary: "iframe src assigned",
      metadata: %{"url" => "/preview-proxy/ws-tools/5173/"}
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id
             })

    refute payload.browser_loaded
    assert payload.operator_visible_state == "src_assigned_no_load"
    assert payload.visibility.diagnostic.reason == "iframe_src_assigned_but_not_loaded"
    assert payload.visibility.diagnostic.next_action =~ "preview_proxy"
    assert payload.visibility.last_browser_event.event == "iframe_src_assigned"
  end

  test "observe_pane reports browser iframe load timeout distinctly" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      session_id: session.id,
      preview_id: session.preview_id,
      source: :browser,
      event: "iframe_load_timeout",
      summary: "iframe load timeout",
      metadata: %{
        "url" => "http://localhost:5173/",
        "iframe_src" => "http://localhost:5173/",
        "diagnostic" => "load_timeout",
        "loaded" => false,
        "recovery_attempts" => 1
      }
    })

    assert {:ok, payload} =
             PreviewTools.invoke("preview_observe_pane", @v3_workspace, %{
               "workspace_id" => @v3_workspace.id,
               "pane_id" => pane_id
             })

    refute payload.browser_loaded
    assert payload.operator_visible_state == "load_timeout"
    assert payload.visibility.diagnostic.reason == "iframe_load_timeout"

    assert payload.visibility.diagnostic.next_action ==
             "reload_preview_iframe_or_reopen_preview_pane"

    assert payload.visibility.last_browser_event.metadata["diagnostic"] == "load_timeout"
  end

  test "open_app_preview reuses an existing preview pane for the same origin" do
    assert {:ok, %{pane_id: first_pane_id, session_id: first_session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:ok, %{pane_id: second_pane_id, session_id: second_session_id, reused: true}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert second_pane_id == first_pane_id
    assert second_session_id == first_session_id
  end

  test "open_app_preview reports unconfirmed visibility honestly" do
    assert {:ok, payload} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    refute payload.user_visible
    refute payload.operator_visible
    assert payload.preview_open_state == "not_visible"
    assert is_binary(payload.agent_next_action)
  end

  test "open_app_preview removes duplicate registered panes for the same session origin" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: first_pane_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:ok, duplicate} =
             PreviewPanes.register(%{
               "pane_id" => "%99",
               "url" => "https://alice.devbox.example.com",
               "workspace" => @v3_workspace,
               "workspace_id" => @v3_workspace.id,
               "cwd" => "/tmp",
               "tmux_session" => tmux_session
             })

    assert duplicate.pane_id == "%99"

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert pane_id == first_pane_id
    assert PreviewPanes.get_by_pane(pane_id)

    duplicate_panes =
      @v3_workspace.id
      |> PreviewPanes.list_for_workspace()
      |> Enum.filter(&(&1.pane_id in [first_pane_id, "%99"]))

    assert length(duplicate_panes) <= 1
  end

  test "open_app_preview does not duplicate an existing pane when force_new_pane is set" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: first_pane_id, session_id: first_session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", ^first_pane_id}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    assert {:ok, %{pane_id: second_pane_id, session_id: second_session_id, reused: true}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "force_new_pane" => true
             })

    assert second_pane_id == first_pane_id
    assert second_session_id == first_session_id
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "open_app_preview recovers a registered pane whose control session is closed" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: pane_id, session_id: stale_session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", ^pane_id}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    stale_session = Repo.get!(ControlSession, stale_session_id)
    stale_session |> ControlSession.changeset(%{status: :closed}) |> Repo.update!()

    assert {:ok, %{pane_id: ^pane_id, session_id: recovered_session_id, reused: true}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert recovered_session_id != stale_session_id
    assert PreviewPanes.get_by_pane(pane_id).control_session_id == recovered_session_id
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "open_localhost_preview rehydrates a tmux preview pane that survived registry restart" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"
    url = "http://localhost:10100/"

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "actor_id" => "agent-1",
               "port" => 10_100
             })

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", ^pane_id}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    PreviewPanes.clear()

    FakeState.put(:fake_tmux_scrollback, %{
      {tmux_session, pane_id} => """
      Preview pane registered
        pane:     #{pane_id}
        url:      #{url}
        display:  #{url}
      """
    })

    assert {:ok, %{pane_id: ^pane_id, reused: true}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "actor_id" => "agent-1",
               "port" => 10_100,
               "force_new_pane" => true
             })

    assert PreviewPanes.get_by_pane(pane_id)
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "open_localhost_preview reuses a single survived preview holder with empty scrollback" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "actor_id" => "agent-1",
               "port" => 10_100
             })

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", ^pane_id}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    PreviewPanes.clear()
    FakeState.put(:fake_tmux_scrollback, %{{tmux_session, pane_id} => ""})

    assert {:ok, %{pane_id: ^pane_id, reused: true}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "actor_id" => "agent-1",
               "port" => 10_100,
               "force_new_pane" => true
             })

    assert PreviewPanes.get_by_pane(pane_id)
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "open_app_preview honors explicit tmux session when an origin is open elsewhere" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    default_session = "#{prefix}default"
    requested_session = "#{prefix}kusaezmc"

    seed_workspace_tmux!(@v3_workspace.id,
      session: requested_session,
      activity: 20,
      pane_id: "%10"
    )

    assert {:ok, %{pane_id: first_pane_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => default_session
             })

    assert PreviewPanes.get_by_pane(first_pane_id).tmux_session == default_session

    assert {:ok, %{pane_id: requested_pane_id} = result} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => requested_session
             })

    refute Map.has_key?(result, :reused)
    assert requested_pane_id != first_pane_id
    assert PreviewPanes.get_by_pane(requested_pane_id).tmux_session == requested_session
    assert_receive {:fake_tmux_split_pane, ^requested_session, "%10", "h", ^requested_pane_id}
  end

  test "open_app_preview picks the more active session when tmux_session is omitted" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    default_session = "#{prefix}default"
    worktree_session = "#{prefix}wt-agent"

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      activity: 20,
      pane_id: "%10"
    )

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert PreviewPanes.get_by_pane(pane_id).tmux_session == worktree_session
    assert_received {:fake_tmux_split_pane, ^worktree_session, "%10", "h", ^pane_id}
    refute_received {:fake_tmux_split_pane, ^default_session, _, _, _}
  end

  test "open_app_preview prefers a session with fresh visibility_heartbeat" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    quiet_session = "#{prefix}quiet"
    active_session = "#{prefix}active"

    seed_workspace_tmux!(@v3_workspace.id,
      session: quiet_session,
      activity: 50,
      pane_id: "%11"
    )

    seed_workspace_tmux!(@v3_workspace.id,
      session: active_session,
      activity: 1,
      pane_id: "%12"
    )

    assert {:ok, %{pane_id: quiet_pane, session: quiet_session_struct}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/",
               tmux_session: quiet_session
             )

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: quiet_pane,
      session_id: quiet_session_struct.id,
      preview_id: quiet_session_struct.preview_id,
      source: :browser,
      event: "visibility_heartbeat",
      summary: "visibility heartbeat",
      metadata: %{"url" => "http://localhost:5173/", "loaded" => true}
    })

    assert {:ok, %{pane_id: picked_pane}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert PreviewPanes.get_by_pane(picked_pane).tmux_session == quiet_session
    assert_received {:fake_tmux_split_pane, ^quiet_session, "%11", "h", ^picked_pane}
  end

  test "open_app_preview rejects when multiple sessions have fresh visibility heartbeats" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    session_a = "#{prefix}a"
    session_b = "#{prefix}b"

    for {session, pane} <- [{session_a, "%20"}, {session_b, "%21"}] do
      seed_workspace_tmux!(@v3_workspace.id, session: session, activity: 10, pane_id: pane)

      assert {:ok, registration} =
               PreviewPanes.register(%{
                 "pane_id" => pane,
                 "url" => "http://localhost:5173/",
                 "workspace" => @v3_workspace,
                 "workspace_id" => @v3_workspace.id,
                 "tmux_session" => session
               })

      PreviewActivity.record(%{
        workspace_id: @v3_workspace.id,
        pane_id: pane,
        session_id: registration.control_session_id,
        preview_id: registration.preview_id,
        source: :browser,
        event: "visibility_heartbeat",
        summary: "visibility heartbeat",
        metadata: %{"url" => "http://localhost:5173/", "loaded" => true}
      })
    end

    assert {:error,
            %{
              error: :ambiguous_tmux_session,
              ambiguous: true,
              candidate_session_names: names
            }} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert session_a in names
    assert session_b in names
    refute_received {:fake_tmux_split_pane, _, _, _, _}
  end

  test "preview_open_here requires tmux_session" do
    assert {:error,
            %{
              error: :missing_tmux_session,
              message: message,
              guidance: guidance
            }} =
             PreviewTools.invoke("preview_open_here", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert message =~ "session-scoped Preview MCP URL"
    assert guidance =~ "pass tmux_session"
  end

  test "preview_open_here opens in the provided tmux session" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, port: 4101)

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      activity: 20,
      pane_id: "%10"
    )

    assert {:ok, %{pane_id: pane_id, placement: placement}} =
             PreviewTools.invoke("preview_open_here", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => worktree_session
             })

    registration = PreviewPanes.get_by_pane(pane_id)
    assert registration.tmux_session == worktree_session
    assert registration.url == "http://localhost:4101"
    assert registration.placement == "beside_agent"
    assert registration.anchor_pane_id == "%10"
    assert registration.anchor_window_id == "@1"
    assert registration.pane_window_id == "@1"
    assert placement.placement == "beside_agent"
    assert placement.anchor_pane_id == "%10"
    assert_receive {:fake_tmux_split_pane, ^worktree_session, "%10", "h", ^pane_id}
  end

  test "preview_ensure_server_here starts the scoped runtime preview server" do
    previous = Application.get_env(:casein, :runtime_preview_launcher_enabled)
    Application.put_env(:casein, :runtime_preview_launcher_enabled, false)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:casein, :runtime_preview_launcher_enabled),
        else: Application.put_env(:casein, :runtime_preview_launcher_enabled, previous)
    end)

    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, runtime_id: "rt-one", port: 4101)

    assert {:ok,
            %{
              status: "queued",
              workspace_id: "ws-tools",
              runtime_id: "rt-one",
              tmux_session: ^worktree_session,
              preview_server: %{"port" => 4101, "tmux_session_id" => ^worktree_session}
            }} =
             PreviewTools.invoke("preview_ensure_server_here", @v3_workspace, %{
               "tmux_session" => worktree_session
             })
  end

  test "preview_open_here repairs an existing preview pane in the wrong window" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, port: 4101)
    seed_multi_window_tmux!(worktree_session)

    {:ok, misplaced} =
      PreviewPanes.register(%{
        "pane_id" => "%20",
        "url" => "http://localhost:4101",
        "workspace" => @v3_workspace,
        "workspace_id" => @v3_workspace.id,
        "cwd" => "/tmp",
        "tmux_session" => worktree_session,
        "placement" => "beside_agent",
        "anchor_pane_id" => "%11",
        "anchor_window_id" => "@1",
        "pane_window_id" => "@2"
      })

    assert misplaced.pane_window_id == "@2"

    assert {:ok, %{pane_id: pane_id, repaired_placement: true, previous_placement: previous}} =
             PreviewTools.invoke("preview_open_here", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => worktree_session
             })

    assert previous.current_window_id == "@2"
    assert previous.expected_window_id == "@1"
    refute PreviewPanes.get_by_pane("%20")
    assert PreviewPanes.get_by_pane(pane_id).pane_window_id == "@1"
    assert_receive {:fake_tmux_split_pane, ^worktree_session, "%11", "h", ^pane_id}
  end

  test "preview_open_app preserves explicit base surface requests under runtime scope" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, port: 4101)

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      activity: 20,
      pane_id: "%10"
    )

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => worktree_session,
               "surface" => "base:app"
             })

    registration = PreviewPanes.get_by_pane(pane_id)
    assert registration.tmux_session == worktree_session
    assert registration.url == "https://alice.devbox.example.com"
  end

  test "preview_open_here rejects explicit base surface requests" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, port: 4101)

    assert {:error, %{error: :runtime_surface_required, message: message}} =
             PreviewTools.invoke("preview_open_here", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => worktree_session,
               "surface" => "base:app"
             })

    assert message =~ "calling runtime"
  end

  test "preview_open_here reports ambiguous runtime surfaces for a scoped session" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, runtime_id: "rt-one", port: 4101)
    seed_runtime_surface!(@v3_workspace.id, worktree_session, runtime_id: "rt-two", port: 4102)

    assert {:error,
            %{
              error: :ambiguous_runtime_surface,
              ambiguous: true,
              candidate_surface_keys: keys,
              message: message
            }} =
             PreviewTools.invoke("preview_open_here", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => worktree_session
             })

    assert "runtime:rt-one:app" in keys
    assert "runtime:rt-two:app" in keys
    assert message =~ "Pass surface"
  end

  test "preview_open_here accepts port disambiguation for runtime surfaces" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    worktree_session = "#{prefix}wt-agent"
    seed_runtime_surface!(@v3_workspace.id, worktree_session, runtime_id: "rt-one", port: 4101)
    seed_runtime_surface!(@v3_workspace.id, worktree_session, runtime_id: "rt-two", port: 4102)

    seed_workspace_tmux!(@v3_workspace.id,
      session: worktree_session,
      activity: 20,
      pane_id: "%10"
    )

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_here", @v3_workspace, %{
               "actor_id" => "agent-1",
               "tmux_session" => worktree_session,
               "port" => 4102
             })

    assert PreviewPanes.get_by_pane(pane_id).url == "http://localhost:4102"
  end

  test "open_app_preview verifies health and asks connected viewers to focus the pane" do
    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "workspace_browser:ws-tools")

    assert {:ok,
            result = %{
              pane_id: pane_id,
              health: %{ready: true, reason: :ok},
              visibility: %{browser_loaded: false, operator_visible_state: "not_rendered"},
              operator_visibility: %{status: "not_confirmed"},
              user_visible: false,
              operator_focus: %{
                status: "queued",
                action: "focus_preview_pane",
                workspace_id: "ws-tools",
                request_id: request_id
              }
            }} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert is_binary(Jason.encode!(result))

    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert_receive {:browser_control,
                    %{
                      "action" => "focus_preview_pane",
                      "actor_id" => "agent-1",
                      "pane_id" => ^pane_id,
                      "request_id" => ^request_id,
                      "tmux_session" => ^tmux_session,
                      "workspace_id" => "ws-tools"
                    }}
  end

  test "open_app_preview confirms operator iframe load before reporting visible" do
    Application.put_env(:casein, :preview_operator_visibility_initial_timeout_ms, 500)
    Application.put_env(:casein, :preview_operator_visibility_iframe_reload_timeout_ms, 0)
    Application.put_env(:casein, :preview_operator_visibility_page_reload_timeout_ms, 0)

    :ok = Phoenix.PubSub.subscribe(Casein.PubSub, "workspace_browser:ws-tools")

    task =
      Task.async(fn ->
        PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})
      end)

    assert_receive {:browser_control, %{"action" => "focus_preview_pane", "pane_id" => pane_id}},
                   10_000

    PreviewActivity.record(%{
      workspace_id: @v3_workspace.id,
      pane_id: pane_id,
      source: :browser,
      event: "iframe_loaded",
      summary: "iframe loaded",
      metadata: %{"url" => "http://localhost:10100/"}
    })

    assert {:ok,
            %{
              visibility: %{browser_loaded: true, operator_visible_state: "browser_loaded"},
              user_visible: true,
              operator_visibility: %{
                status: "confirmed",
                confirmed_by: "iframe_loaded"
              }
            }} = Task.await(task)
  end

  test "new_control_session does not force another preview pane for the same origin" do
    assert {:ok, %{pane_id: first_pane_id, session_id: first_session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:ok, %{pane_id: second_pane_id, session_id: second_session_id, reused: true}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "new_control_session" => true
             })

    assert second_pane_id == first_pane_id
    assert second_session_id == first_session_id
  end

  test "share_session opens another pane attached to the same control session" do
    assert {:ok, %{pane_id: first_pane_id, session_id: first_session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:ok,
            %{
              pane_id: second_pane_id,
              session_id: second_session_id,
              shared: true,
              source_pane_id: ^first_pane_id
            }} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "share_session" => true
             })

    assert second_pane_id != first_pane_id
    assert second_session_id == first_session_id
    assert PreviewPanes.get_by_pane(second_pane_id).shared == true
  end

  test "share_session fails clearly when no source preview pane exists" do
    assert {:error, %{error: :no_shared_preview_found, message: message}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1",
               "share_session" => true
             })

    assert message =~ "No active preview pane"
    refute_received {:fake_tmux_split_pane, _, _, _, _}
  end

  test "split_preview_pane avoids nesting inside active preview pane" do
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:ok, %{pane_id: first_preview_pane_id}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", ^first_preview_pane_id}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}

    :ok = FakeAdapter.select_pane(tmux_session, first_preview_pane_id)

    assert {:ok, %{pane_id: second_preview_pane_id}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5174/", [])

    assert_receive {:fake_tmux_split_pane, ^tmux_session, "%1", "h", ^second_preview_pane_id}
    assert_receive {:fake_tmux_select_pane, ^tmux_session, "%1"}
  end

  test "split_preview_pane picks attached session with freshest activity when multiple match" do
    prefix = Tmux.workspace_session_prefix(@v3_workspace.id)
    stale = "#{prefix}stale"
    fresh = "#{prefix}fresh"
    older = "#{prefix}older-attached"

    for {session, activity} <- [{stale, 10}, {fresh, 20}, {older, 5}] do
      seed_workspace_tmux!(@v3_workspace.id, session: session, activity: activity)
    end

    FakeState.put(:fake_tmux_session_meta, %{
      fresh => %{attached: true},
      older => %{attached: true}
    })

    assert {:ok, %{pane_id: pane_id}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert is_binary(pane_id)
    assert PreviewPanes.get_by_pane(pane_id).tmux_session == fresh
  end

  test "invoke open_app auto-navigates loopback Casein to the workspace viewer" do
    previous_on_devbox = Application.get_env(:casein, :on_devbox)
    previous_app_url = Application.get_env(:casein, :preview_app_url)
    previous_loopback = Application.get_env(:casein, :preview_loopback_port)
    previous_root = Application.get_env(:casein, :workspaces_root)

    workspace_dir =
      Path.join(System.tmp_dir!(), "preview-loopback-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_dir)
    Application.put_env(:casein, :workspaces_root, Path.dirname(workspace_dir))
    Application.put_env(:casein, :on_devbox, true)
    Application.put_env(:casein, :preview_loopback_port, 4000)
    Application.put_env(:casein, :preview_app_url, "https://casein.example.com")

    on_exit(fn ->
      File.rm_rf(workspace_dir)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:preview_app_url, previous_app_url)
      restore_preview_loopback_port(previous_loopback)
      restore_env(:workspaces_root, previous_root)
    end)

    ws = %{
      id: "ws-loopback",
      path: workspace_dir,
      metadata: %{attached_folder: true, terminal_output: "unavailable", detected_ports: []}
    }

    seed_workspace_tmux!("ws-loopback")

    assert {:ok, %{navigated_to: navigated_to, current_url: current_url, pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_app", ws, %{
               "surface" => "app-local",
               "actor_id" => "agent-1"
             })

    assert is_binary(pane_id)
    assert navigated_to =~ "/workspaces/ws-loopback"
    assert current_url =~ "/workspaces/ws-loopback"
  end

  test "invoke open_app reports navigation_failed when loopback navigate is blocked" do
    bypass = HTTPStub.open()
    port = bypass.port

    previous_on_devbox = Application.get_env(:casein, :on_devbox)
    previous_app_url = Application.get_env(:casein, :preview_app_url)
    previous_loopback = Application.get_env(:casein, :preview_loopback_port)
    previous_root = Application.get_env(:casein, :workspaces_root)
    previous_adapter = Application.get_env(:casein, :preview_control_adapter)

    workspace_dir =
      Path.join(System.tmp_dir!(), "preview-nav-fail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_dir)
    Application.put_env(:casein, :workspaces_root, Path.dirname(workspace_dir))
    Application.put_env(:casein, :on_devbox, true)
    Application.put_env(:casein, :preview_app_url, "https://casein.example.com")
    Application.put_env(:casein, :preview_loopback_port, port)
    Application.put_env(:casein, :preview_control_adapter, :playwright)

    on_exit(fn ->
      File.rm_rf(workspace_dir)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:preview_app_url, previous_app_url)
      restore_preview_loopback_port(previous_loopback)
      restore_env(:workspaces_root, previous_root)
      restore_env(:preview_control_adapter, previous_adapter)
    end)

    HTTPStub.expect_once(bypass, "GET", "/workspaces/ws-nav-fail", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://evil.example/")
      |> Plug.Conn.resp(302, "")
    end)

    ws = %{
      id: "ws-nav-fail",
      path: workspace_dir,
      metadata: %{
        attached_folder: true,
        terminal_output: "unavailable",
        detected_ports: [port]
      }
    }

    seed_workspace_tmux!("ws-nav-fail")

    assert {:ok, payload} =
             PreviewTools.invoke("preview_open_app", ws, %{
               "surface" => "app-local",
               "actor_id" => "agent-1"
             })

    refute Map.has_key?(payload, :navigated_to)

    assert %{error: :redirect_blocked, status: 302, location: "http://evil.example/"} =
             payload.navigation_failed
  end

  test "invoke open_localhost rewrites loopback root path to /workspaces" do
    previous = Application.get_env(:casein, :preview_loopback_port)
    Application.put_env(:casein, :preview_loopback_port, 4000)
    on_exit(fn -> restore_preview_loopback_port(previous) end)
    workspace = put_in(@v3_workspace, [:metadata, :ports, "casein"], 4000)

    assert {:ok, %{current_url: url, pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_localhost", workspace, %{
               "port" => 4000,
               "path" => "/",
               "actor_id" => "agent-1"
             })

    assert is_binary(pane_id)

    assert url == "http://localhost:4000/workspaces"
  end

  test "invoke open_localhost opens a workspace-declared dev port" do
    workspace = put_in(@v3_workspace, [:metadata, :ports, "dev"], 5173)

    assert {:ok, %{session_id: session_id, current_url: url, pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_localhost", workspace, %{
               "port" => 5173,
               "path" => "/index.html",
               "actor_id" => "agent-1"
             })

    assert is_integer(session_id)
    assert is_binary(pane_id)
    assert url == "http://localhost:5173/index.html"
  end

  test "invoke open_localhost reuses an existing pane for the same origin" do
    bypass = HTTPStub.open()
    Application.put_env(:casein, :preview_open_preflight, true)

    HTTPStub.expect(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)

    ws = Map.put(@v3_workspace, :metadata, detected_port_metadata(bypass.port))

    assert {:ok, %{session_id: first_session_id, pane_id: first_pane_id}} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1"
             })

    assert {:ok, %{session_id: second_session_id, pane_id: second_pane_id, reused: true}} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1",
               "new_control_session" => true
             })

    assert second_pane_id == first_pane_id
    assert second_session_id == first_session_id
  end

  test "invoke open_localhost rejects a stale existing pane when the origin no longer responds" do
    bypass = HTTPStub.open()
    Application.put_env(:casein, :preview_open_preflight, true)

    HTTPStub.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)

    ws = Map.put(@v3_workspace, :metadata, detected_port_metadata(bypass.port))

    assert {:ok, %{pane_id: first_pane_id}} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1"
             })

    HTTPStub.down(bypass)

    assert {:error,
            %{
              error: :preview_unreachable,
              message: "Preview URL is unreachable; no preview pane was opened."
            }} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1",
               "new_control_session" => true
             })

    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert [_operator, %{id: ^first_pane_id}] =
             FakeState.get(:fake_tmux_panes, %{}) |> Map.fetch!(tmux_session)
  end

  test "invoke open_localhost rejects unreachable URL before splitting tmux" do
    bypass = HTTPStub.open()
    HTTPStub.down(bypass)
    Application.put_env(:casein, :preview_open_preflight, true)

    ws = Map.put(@v3_workspace, :metadata, detected_port_metadata(bypass.port))
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:error,
            %{
              error: :preview_unreachable,
              url: "http://localhost:" <> _,
              message: "Preview URL is unreachable; no preview pane was opened."
            }} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1"
             })

    assert [%{id: "%1"}] = FakeState.get(:fake_tmux_panes, %{}) |> Map.fetch!(tmux_session)
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "invoke open_localhost rejects HTTP 404 before splitting tmux" do
    bypass = HTTPStub.open()
    Application.put_env(:casein, :preview_open_preflight, true)

    HTTPStub.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 404, "missing")
    end)

    ws = Map.put(@v3_workspace, :metadata, detected_port_metadata(bypass.port))
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:error,
            %{
              error: :preview_http_status,
              status: 404,
              message: "Preview URL responded with HTTP 404; no preview pane was opened."
            }} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1"
             })

    assert [%{id: "%1"}] = FakeState.get(:fake_tmux_panes, %{}) |> Map.fetch!(tmux_session)
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "invoke open_localhost classifies the preview-router fallback 404 as workspace_app_not_running" do
    bypass = HTTPStub.open()
    Application.put_env(:casein, :preview_open_preflight, true)

    # Mirrors what Casein's preview-router (scripts/preview-router.sh) returns
    # when a stopped workspace's subdomain falls through Caddy.
    HTTPStub.expect_once(bypass, "GET", "/", fn conn ->
      Plug.Conn.resp(conn, 404, "No active preview environment for localhost:#{bypass.port}")
    end)

    ws = Map.put(@v3_workspace, :metadata, detected_port_metadata(bypass.port))
    tmux_session = "#{Tmux.workspace_session_prefix(@v3_workspace.id)}default"

    assert {:error, %{error: :workspace_app_not_running, status: 404, message: message}} =
             PreviewTools.invoke("preview_open_localhost", ws, %{
               "port" => bypass.port,
               "actor_id" => "agent-1"
             })

    assert message =~ "not running"

    # A plain 404 (no marker body) still classifies as the generic http-status error.
    assert [%{id: "%1"}] = FakeState.get(:fake_tmux_panes, %{}) |> Map.fetch!(tmux_session)
    refute_received {:fake_tmux_split_pane, ^tmux_session, _, _, _}
  end

  test "invoke open_localhost rejects disallowed ports" do
    assert {:error, %{error: :port_not_allowed, port: 9999, allowed_ports: allowed_ports}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{"port" => 9999})

    assert 5173 in allowed_ports
  end

  test "resolve_workspace returns guidance for missing references" do
    assert {:error,
            %{
              error: :missing_workspace_reference,
              folder_id_format: "folder:<base64url-absolute-path>"
            }} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{})
  end

  test "resolve_workspace attaches an allowed folder path" do
    root =
      Path.join(System.tmp_dir!(), "preview-tools-root-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:casein, :workspaces_root, root)

    assert {:ok, %{workspace_id: "folder:" <> _encoded, path: ^workspace}} =
             PreviewTools.invoke("preview_resolve_workspace", %{}, %{
               "workspace_path" => workspace
             })
  end

  test "invoke navigate moves within allowed origin" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{"actor_id" => "agent-1"})

    assert {:ok, observation} =
             PreviewTools.invoke("preview_navigate", @v3_workspace, %{
               "session_id" => session_id,
               "path" => "/settings"
             })

    assert observation.url =~ "/settings"
  end

  test "invoke navigate_pane updates an embedded preview pane" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert {:ok,
            %{
              pane_id: ^pane_id,
              session_id: session_id,
              current_url: "http://localhost:5173/settings",
              display_url: "http://localhost:5173/settings"
            }} =
             PreviewTools.invoke("preview_navigate_pane", @v3_workspace, %{
               "pane_id" => pane_id,
               "path" => "/settings"
             })

    assert session_id == session.id
    assert PreviewPanes.get_by_pane(pane_id).display_url == "http://localhost:5173/settings"
  end

  test "invoke click falls back to a visible snapshot when browser pane ack is unavailable" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert {:ok,
            %{
              url: "http://localhost:5173/settings",
              pane_id: ^pane_id,
              display_url: display_url,
              snapshot_url: snapshot_url,
              visible_effect: "snapshot"
            }} =
             PreviewTools.invoke("preview_click", @v3_workspace, %{
               "session_id" => session.id,
               "selector" => ~s(a[href="/settings"])
             })

    assert display_url == snapshot_url
    assert display_url =~ "/preview-artifacts/"
    assert PreviewPanes.get_by_pane(pane_id).display_url == display_url
  end

  test "invoke click reports confirmed when visible preview pane acknowledges the action" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    parent = self()

    browser =
      spawn(fn ->
        Phoenix.PubSub.subscribe(Casein.PubSub, "workspace_browser:#{@v3_workspace.id}")
        send(parent, :browser_ready)

        receive do
          {:browser_control, %{"action" => "preview_pane_action"} = payload} ->
            PreviewActivity.record(%{
              workspace_id: payload["workspace_id"],
              pane_id: payload["pane_id"],
              session_id: session.id,
              source: :browser,
              event: "visible_click",
              summary: "visible click",
              metadata: %{
                "request_id" => payload["request_id"],
                "status" => "ok"
              }
            })
        end
      end)

    assert_receive :browser_ready

    assert {:ok,
            %{
              session_id: session_id,
              pane_id: ^pane_id,
              visible_effect: "confirmed",
              mode: "iframe"
            }} =
             PreviewTools.invoke("preview_click", @v3_workspace, %{
               "session_id" => session.id,
               "selector" => ~s(a[href="/settings"])
             })

    assert session_id == session.id
    ref = Process.monitor(browser)
    assert_receive {:DOWN, ^ref, :process, ^browser, reason} when reason in [:normal, :noproc]
  end

  test "invoke click shows a snapshot when link navigation cannot be embedded" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert {:ok,
            %{
              url: "https://example.com/news",
              pane_id: ^pane_id,
              display_url: display_url,
              snapshot_url: snapshot_url,
              pane_sync_warning: ":untrusted_preview_url"
            }} =
             PreviewTools.invoke("preview_click", @v3_workspace, %{
               "session_id" => session.id,
               "selector" => ~s(a[href="https://example.com/news"])
             })

    assert display_url == snapshot_url
    assert display_url =~ "/preview-artifacts/"
    assert PreviewPanes.get_by_pane(pane_id).display_url == display_url
  end

  test "invoke opens app preview and observes it" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, observation} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})

    assert observation.url =~ "alice.devbox.example.com"
  end

  test "invoke observes live browser state" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, observation} =
             PreviewTools.invoke("preview_observe_live", @v3_workspace, %{
               "session_id" => session_id
             })

    assert observation.url =~ "alice.devbox.example.com"
    assert is_map(observation.dom_summary)
    assert observation.next_tool == "preview_elements"
    assert observation.next_arguments == %{session_id: session_id}
  end

  test "preview_elements returns element_id targets" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, %{elements: elements, next_tool: "preview_click"}} =
             PreviewTools.invoke("preview_elements", @v3_workspace, %{
               "session_id" => session_id
             })

    assert %{element_id: element_id, selector: ~s(a[href="/settings"]), role: "link"} =
             Enum.find(elements, &(&1.name == "Settings"))

    assert element_id =~ "el_"
  end

  test "preview_click accepts element_id from preview_elements" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, %{elements: elements}} =
             PreviewTools.invoke("preview_elements", @v3_workspace, %{
               "session_id" => session_id
             })

    %{element_id: element_id} = Enum.find(elements, &(&1.name == "Settings"))

    assert {:ok, observation} =
             PreviewTools.invoke("preview_click", @v3_workspace, %{
               "session_id" => session_id,
               "element_id" => element_id
             })

    assert observation.url =~ "/settings"
  end

  test "preview_type accepts element_id from preview_elements" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, %{elements: elements}} =
             PreviewTools.invoke("preview_elements", @v3_workspace, %{
               "session_id" => session_id,
               "query" => "search"
             })

    %{element_id: element_id} = Enum.find(elements, &(&1.name == "Search"))

    assert {:ok, observation} =
             PreviewTools.invoke("preview_type", @v3_workspace, %{
               "session_id" => session_id,
               "element_id" => element_id,
               "text" => "phoenix"
             })

    assert get_in(observation, [:dom_summary, :values, "input[name=q]"]) == "phoenix"

    assert {:ok, observation} =
             PreviewTools.invoke("preview_type", @v3_workspace, %{
               "session_id" => session_id,
               "element_id" => element_id,
               "text" => ""
             })

    assert get_in(observation, [:dom_summary, :values, "input[name=q]"]) == ""
  end

  test "invoke returns preview origin storage" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok,
            %{
              local_storage: %{},
              session_storage: %{},
              url: url
            }} =
             PreviewTools.invoke("preview_get_storage", @v3_workspace, %{
               "session_id" => session_id
             })

    assert url =~ "alice.devbox.example.com"
  end

  test "invoke report_errors returns console and network observations" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    insert_observation!(session_id, "console_errors", %{
      "errors" => [%{"type" => "console", "text" => "boom"}]
    })

    insert_observation!(session_id, "network_errors", %{
      "errors" => [%{"type" => "response", "status" => 500}]
    })

    assert {:ok,
            %{
              console_errors: [%{"type" => "console", "text" => "boom"}],
              network_errors: [%{"type" => "response", "status" => 500}]
            }} =
             PreviewTools.invoke("preview_report_errors", @v3_workspace, %{
               "session_id" => session_id
             })
  end

  test "invoke closes an open preview session" do
    assert {:ok, %{session_id: session_id}} =
             PreviewTools.invoke("preview_open_app", @v3_workspace, %{
               "actor_id" => "agent-1"
             })

    assert {:ok, %{session_id: ^session_id, status: :closed}} =
             PreviewTools.invoke("preview_close", @v3_workspace, %{"session_id" => session_id})

    assert {:error, :not_found} =
             PreviewTools.invoke("preview_observe", @v3_workspace, %{"session_id" => session_id})
  end

  test "list_surfaces returns manager surfaces for planning" do
    surfaces = PreviewTools.list_surfaces(@v3_workspace)
    assert Enum.any?(surfaces, &(&1.name == "app"))
  end

  defp restore_preview_loopback_port(nil),
    do: Application.delete_env(:casein, :preview_loopback_port)

  defp restore_preview_loopback_port(value),
    do: Application.put_env(:casein, :preview_loopback_port, value)

  defp detected_port_metadata(port) do
    %{
      terminal_output: "Serving at http://localhost:#{port}/",
      detected_ports: [port],
      tidewave_ports: [],
      tidewave_probed_ports: [port]
    }
  end

  defp restore_env(key, value) do
    if is_nil(value),
      do: Application.delete_env(:casein, key),
      else: Application.put_env(:casein, key, value)
  end

  defp restore_fake_state(key, nil), do: FakeState.delete(key)
  defp restore_fake_state(key, value), do: FakeState.put(key, value)

  defp insert_observation!(session_id, kind, data) do
    %ControlObservation{}
    |> ControlObservation.changeset(%{session_id: session_id, kind: kind, data: data})
    |> Repo.insert!()
  end
end
