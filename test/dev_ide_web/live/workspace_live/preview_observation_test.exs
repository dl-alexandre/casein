defmodule DevIdeWeb.WorkspaceLive.PreviewObservationTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Audit
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()
    unique = System.unique_integer([:positive])
    workspace_id = "prevobs-#{unique}"
    workspace_name = "prevobs-ws-#{unique}"
    workspace_root = Path.join(System.tmp_dir!(), "devide-prevobs-live-#{unique}")
    workspace_path = Path.join(workspace_root, workspace_id)
    File.mkdir_p!(workspace_path)

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_user = Application.get_env(:dev_ide, :current_user)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)
    # The :browser ForwardAuth plug overrides session identity, so set the test
    # user via application env (the plug's static fallback) rather than the session.
    Application.put_env(:dev_ide, :current_user, %{
      id: "tester",
      username: "tester",
      email: "tester@local",
      role: :owner
    })

    MemoryAdapter.clear()
    Audit.clear()

    Bypass.stub(bypass, "GET", "/api/workspaces/#{workspace_id}/status", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => workspace_id,
          "name" => workspace_name,
          "user" => "tester",
          "status" => "stopped",
          "type" => "v3",
          "branch" => "master",
          "path" => workspace_path
        })
      )
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Audit.clear()
      File.rm_rf(workspace_root)

      restore = fn key, prev ->
        if prev,
          do: Application.put_env(:dev_ide, key, prev),
          else: Application.delete_env(:dev_ide, key)
      end

      restore.(:manager_url, prev_manager)
      restore.(:workspaces_root, prev_root)
      restore.(:current_user, prev_user)
    end)

    {:ok, workspace_id: workspace_id, workspace_name: workspace_name}
  end

  defp broadcast(workspace_id, message) do
    Phoenix.PubSub.broadcast(DevIde.PubSub, "preview:" <> workspace_id, message)
  end

  test "agent-driven preview observation does not crash the cockpit LiveView", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    observation = %{
      url: "https://example.com/agent-page",
      title: "Agent Page",
      dom_summary: %{"headings" => ["Welcome"]}
    }

    broadcast(workspace_id, {
      :preview_observation,
      %{preview_id: "preview-no-pane", session_id: "sess-1", observation: observation}
    })

    # Without a handle_info clause for {:preview_observation, _}, the LiveView
    # process raises FunctionClauseError on this message and dies. Round-trip a
    # render to prove the process is still alive and serving.
    assert render(view) =~ "workspace-main-header"
    assert Process.alive?(view.pid)
  end

  test "a heartbeat re-registration does not steal the active highlight", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    register = fn pane_id, display_url ->
      broadcast(workspace_id, {
        :preview_pane_registered,
        %{
          pane_id: pane_id,
          workspace_id: workspace_id,
          preview_id: "preview-#{pane_id}",
          url: display_url,
          display_url: display_url,
          control_session_id: "sess-#{pane_id}"
        }
      })

      assert render(view) =~ "workspace-main-header"
    end

    register.("%70", "https://example.com/a")
    register.("%71", "https://example.com/b")

    assert :sys.get_state(view.pid).socket.assigns.ui_highlight_pane_id == "%71"

    # A heartbeat re-broadcast for the first pane (unchanged display URL) must not
    # re-grab the highlight — doing so re-enters the focus path and flashes the
    # live preview frame on every heartbeat.
    register.("%70", "https://example.com/a")

    assert :sys.get_state(view.pid).socket.assigns.ui_highlight_pane_id == "%71"
  end

  test "preview observation reflects the latest url/title into the matching panel", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    preview_id = "preview-#{System.unique_integer([:positive])}"
    pane_id = "%42"

    broadcast(workspace_id, {
      :preview_pane_registered,
      %{
        pane_id: pane_id,
        workspace_id: workspace_id,
        preview_id: preview_id,
        url: "https://example.com/start",
        display_url: "https://example.com/start",
        control_session_id: "sess-1"
      }
    })

    # Drain the registration before observing.
    assert render(view) =~ "workspace-main-header"

    broadcast(workspace_id, {
      :preview_observation,
      %{
        preview_id: preview_id,
        session_id: "sess-1",
        observation: %{
          url: "https://example.com/navigated",
          title: "Navigated",
          dom_summary: %{"headings" => ["Navigated"]}
        }
      }
    })

    # Process survives and the pane assign now carries the agent's latest url.
    assert render(view) =~ "workspace-main-header"
    assert Process.alive?(view.pid)

    pane = :sys.get_state(view.pid).socket.assigns.preview_panes[pane_id]
    assert pane.url == "https://example.com/navigated"
    assert pane.display_url == "https://example.com/navigated"
    assert pane.title == "Navigated"
  end

  test "preview observation reflects into all panels sharing the preview", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    preview_id = "preview-#{System.unique_integer([:positive])}"
    pane_ids = ["%52", "%53"]

    for pane_id <- pane_ids do
      broadcast(workspace_id, {
        :preview_pane_registered,
        %{
          pane_id: pane_id,
          workspace_id: workspace_id,
          preview_id: preview_id,
          url: "https://example.com/start",
          display_url: "https://example.com/start",
          control_session_id: "sess-1",
          shared: pane_id == "%53",
          source_pane_id: if(pane_id == "%53", do: "%52")
        }
      })
    end

    assert render(view) =~ "workspace-main-header"

    broadcast(workspace_id, {
      :preview_observation,
      %{
        preview_id: preview_id,
        session_id: "sess-1",
        observation: %{
          url: "https://example.com/shared",
          title: "Shared",
          dom_summary: %{"headings" => ["Shared"]}
        }
      }
    })

    assert render(view) =~ "workspace-main-header"

    panes = :sys.get_state(view.pid).socket.assigns.preview_panes

    for pane_id <- pane_ids do
      assert panes[pane_id].url == "https://example.com/shared"
      assert panes[pane_id].display_url == "https://example.com/shared"
      assert panes[pane_id].title == "Shared"
    end
  end

  test "preview observation keeps localhost app urls proxied for the browser", %{
    conn: conn,
    workspace_id: workspace_id
  } do
    prev_proxy_enabled = Application.fetch_env(:dev_ide, :preview_proxy_enabled)
    prev_app_url = Application.fetch_env(:dev_ide, :preview_app_url)

    Application.put_env(:dev_ide, :preview_proxy_enabled, true)
    Application.put_env(:dev_ide, :preview_app_url, "https://devide.example.com")

    on_exit(fn ->
      restore = fn
        key, {:ok, prev} -> Application.put_env(:dev_ide, key, prev)
        key, :error -> Application.delete_env(:dev_ide, key)
      end

      restore.(:preview_proxy_enabled, prev_proxy_enabled)
      restore.(:preview_app_url, prev_app_url)
    end)

    {:ok, view, _html} = live(conn, ~p"/workspaces/#{workspace_id}?host=local")

    preview_id = "preview-#{System.unique_integer([:positive])}"
    pane_id = "%43"

    broadcast(workspace_id, {
      :preview_pane_registered,
      %{
        pane_id: pane_id,
        workspace_id: workspace_id,
        preview_id: preview_id,
        url: "http://localhost:41034/",
        display_url: "/preview-proxy/#{workspace_id}/41034/",
        control_session_id: "sess-1"
      }
    })

    assert render(view) =~ "workspace-main-header"

    broadcast(workspace_id, {
      :preview_observation,
      %{
        preview_id: preview_id,
        session_id: "sess-1",
        observation: %{
          url: "http://localhost:41034/superadmin?preview_superadmin=1",
          title: "Superadmin"
        }
      }
    })

    assert render(view) =~ "workspace-main-header"

    pane = :sys.get_state(view.pid).socket.assigns.preview_panes[pane_id]

    assert pane.url == "http://localhost:41034/superadmin?preview_superadmin=1"

    assert pane.display_url ==
             "/preview-proxy/#{workspace_id}/41034/superadmin?preview_superadmin=1"
  end
end
