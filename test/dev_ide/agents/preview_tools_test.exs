defmodule DevIDE.Agents.PreviewToolsTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Agents.PreviewTools
  alias DevIDE.PreviewControl.Registry
  alias DevIDE.PreviewPanes
  alias DevIDE.Previews.ControlObservation
  alias DevIDE.Terminals.Tmux
  alias DevIde.Repo
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
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_tmux = Application.get_env(:dev_ide, :tmux_adapter)
    prev_api_token = Application.get_env(:dev_ide, :dev_ide_api_token)
    prev_fake_tmux_pid = FakeState.get(:fake_tmux_test_pid)
    Application.put_env(:dev_ide, :tmux_adapter, FakeAdapter)
    Application.put_env(:dev_ide, :dev_ide_api_token, "preview-tools-test-token")
    FakeState.put(:fake_tmux_test_pid, self())
    _ = Registry.clear()
    PreviewPanes.clear()
    seed_workspace_tmux!(@v3_workspace.id)

    on_exit(fn ->
      PreviewPanes.clear()
      FakeState.delete(:fake_tmux_windows)
      FakeState.delete(:fake_tmux_panes)
      FakeState.delete(:fake_tmux_alive_sessions)
      FakeState.delete(:fake_tmux_session_meta)
      restore_fake_state(:fake_tmux_test_pid, prev_fake_tmux_pid)

      if is_nil(prev_root),
        do: Application.delete_env(:dev_ide, :workspaces_root),
        else: Application.put_env(:dev_ide, :workspaces_root, prev_root)

      restore_env(:tmux_adapter, prev_tmux)
      restore_env(:dev_ide_api_token, prev_api_token)
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
    assert "preview_open_app" in names
    assert "preview_open_localhost" in names
    assert "preview_navigate" in names
    assert "preview_navigate_pane" in names
    assert "preview_observe" in names
    assert "preview_observe_live" in names
    assert "preview_screenshot" in names
    assert "preview_close" in names
    assert "preview_get_storage" in names
    assert "preview_reload_iframe" in names
    assert "devide_reload_page" in names
  end

  test "reload tools broadcast workspace browser control requests" do
    :ok = Phoenix.PubSub.subscribe(DevIde.PubSub, "workspace_browser:ws-tools")

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
             PreviewTools.invoke("devide_reload_page", @v3_workspace, %{"actor_id" => "agent-1"})

    assert_receive {:browser_control,
                    %{
                      "action" => "reload_page",
                      "actor_id" => "agent-1",
                      "request_id" => ^page_request_id,
                      "workspace_id" => "ws-tools"
                    }}
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

  test "resolve_workspace reports attached_folder without question mark suffix" do
    root =
      Path.join(System.tmp_dir!(), "preview-tools-attached-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "demo")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:dev_ide, :workspaces_root, root)

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
      :code.priv_dir(:dev_ide)
      |> List.to_string()
      |> Path.join("scripts/devide-preview")

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
    assert command =~ "DEV_IDE_API_TOKEN="
    assert command =~ "DEVIDE_WORKSPACE_ID=#{@v3_workspace.id}"
    assert command =~ "http://localhost:5173/"

    assert {:ok, %{status: :closed}} =
             PreviewTools.invoke("preview_close", %{}, %{"session_id" => session.id})

    refute PreviewPanes.get_by_pane(pane_id)
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

  test "invoke open_app auto-navigates loopback DevIDE to the workspace viewer" do
    previous_on_devbox = Application.get_env(:dev_ide, :on_devbox)
    previous_app_url = Application.get_env(:dev_ide, :preview_app_url)
    previous_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    previous_root = Application.get_env(:dev_ide, :workspaces_root)

    workspace_dir =
      Path.join(System.tmp_dir!(), "preview-loopback-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_dir)
    Application.put_env(:dev_ide, :workspaces_root, Path.dirname(workspace_dir))
    Application.put_env(:dev_ide, :on_devbox, true)
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)
    Application.put_env(:dev_ide, :preview_app_url, "https://devide.example.com")

    on_exit(fn ->
      File.rm_rf(workspace_dir)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:preview_app_url, previous_app_url)
      restore_preview_loopback_port(previous_loopback)
      restore_env(:workspaces_root, previous_root)
    end)

    ws = %{id: "ws-loopback", path: workspace_dir, metadata: %{attached_folder: true}}
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
    bypass = Bypass.open()
    port = bypass.port

    previous_on_devbox = Application.get_env(:dev_ide, :on_devbox)
    previous_app_url = Application.get_env(:dev_ide, :preview_app_url)
    previous_loopback = Application.get_env(:dev_ide, :preview_loopback_port)
    previous_root = Application.get_env(:dev_ide, :workspaces_root)
    previous_adapter = Application.get_env(:dev_ide, :preview_control_adapter)

    workspace_dir =
      Path.join(System.tmp_dir!(), "preview-nav-fail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_dir)
    Application.put_env(:dev_ide, :workspaces_root, Path.dirname(workspace_dir))
    Application.put_env(:dev_ide, :on_devbox, true)
    Application.put_env(:dev_ide, :preview_app_url, "https://devide.example.com")
    Application.put_env(:dev_ide, :preview_loopback_port, port)
    Application.put_env(:dev_ide, :preview_control_adapter, :playwright)

    on_exit(fn ->
      File.rm_rf(workspace_dir)
      restore_env(:on_devbox, previous_on_devbox)
      restore_env(:preview_app_url, previous_app_url)
      restore_preview_loopback_port(previous_loopback)
      restore_env(:workspaces_root, previous_root)
      restore_env(:preview_control_adapter, previous_adapter)
    end)

    Bypass.expect_once(bypass, "GET", "/workspaces/ws-nav-fail", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "http://evil.example/")
      |> Plug.Conn.resp(302, "")
    end)

    ws = %{
      id: "ws-nav-fail",
      path: workspace_dir,
      metadata: %{attached_folder: true, detected_ports: [port]}
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
    previous = Application.get_env(:dev_ide, :preview_loopback_port)
    Application.put_env(:dev_ide, :preview_loopback_port, 4000)
    on_exit(fn -> restore_preview_loopback_port(previous) end)

    assert {:ok, %{current_url: url, pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "port" => 4000,
               "path" => "/",
               "actor_id" => "agent-1"
             })

    assert is_binary(pane_id)

    assert url == "http://localhost:4000/workspaces"
  end

  test "invoke open_localhost opens a common dev port" do
    assert {:ok, %{session_id: session_id, current_url: url, pane_id: pane_id}} =
             PreviewTools.invoke("preview_open_localhost", @v3_workspace, %{
               "port" => 5173,
               "path" => "/index.html",
               "actor_id" => "agent-1"
             })

    assert is_integer(session_id)
    assert is_binary(pane_id)
    assert url == "http://localhost:5173/index.html"
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
    Application.put_env(:dev_ide, :workspaces_root, root)

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

  test "invoke click syncs embedded preview pane after link navigation" do
    assert {:ok, %{pane_id: pane_id, session: session}} =
             PreviewTools.split_preview_pane(@v3_workspace, "http://localhost:5173/", [])

    assert {:ok,
            %{
              url: "http://localhost:5173/settings",
              pane_id: ^pane_id,
              display_url: "http://localhost:5173/settings"
            }} =
             PreviewTools.invoke("preview_click", @v3_workspace, %{
               "session_id" => session.id,
               "selector" => ~s(a[href="/settings"])
             })

    assert PreviewPanes.get_by_pane(pane_id).display_url == "http://localhost:5173/settings"
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
    do: Application.delete_env(:dev_ide, :preview_loopback_port)

  defp restore_preview_loopback_port(value),
    do: Application.put_env(:dev_ide, :preview_loopback_port, value)

  defp restore_env(key, value) do
    if is_nil(value),
      do: Application.delete_env(:dev_ide, key),
      else: Application.put_env(:dev_ide, key, value)
  end

  defp restore_fake_state(key, nil), do: FakeState.delete(key)
  defp restore_fake_state(key, value), do: FakeState.put(key, value)

  defp insert_observation!(session_id, kind, data) do
    %ControlObservation{}
    |> ControlObservation.changeset(%{session_id: session_id, kind: kind, data: data})
    |> Repo.insert!()
  end
end
