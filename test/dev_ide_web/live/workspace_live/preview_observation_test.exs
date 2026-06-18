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
          "user" => "alice",
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
end
