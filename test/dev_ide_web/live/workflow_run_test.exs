defmodule DevIdeWeb.WorkspaceLive.WorkflowRunTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DevIDE.Runners
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  setup do
    bypass = Bypass.open()

    workspace_root =
      Path.join(System.tmp_dir!(), "workflow-run-#{System.unique_integer([:positive])}")

    workspace_path = Path.join(workspace_root, "ws-1")
    File.mkdir_p!(Path.join(workspace_path, ".dev_ide/workflows"))

    prev_manager = Application.get_env(:dev_ide, :manager_url)
    prev_root = Application.get_env(:dev_ide, :workspaces_root)

    Application.put_env(:dev_ide, :manager_url, "http://localhost:#{bypass.port}")
    Application.put_env(:dev_ide, :workspaces_root, workspace_root)

    MemoryAdapter.clear()
    Runners.clear()

    write_workflow(workspace_path, "precommit.yaml", """
    name: Precommit
    description: Full precommit gate
    command: mix precommit
    """)

    seed_workspace("ws-1", workspace_path)

    Bypass.stub(bypass, "GET", "/api/workspaces/ws-1/status", fn conn ->
      workspace_payload(conn, workspace_path)
    end)

    on_exit(fn ->
      MemoryAdapter.clear()
      Runners.clear()
      File.rm_rf(workspace_root)
      restore(:manager_url, prev_manager)
      restore(:workspaces_root, prev_root)
    end)

    {:ok, workspace_path: workspace_path}
  end

  test "workflow:run queues a repository workflow", %{conn: conn, workspace_path: workspace_path} do
    {:ok, view, _html} = live(conn, ~p"/workspaces/ws-1?host=local")

    command_id = workflow_command_id(workspace_path, "ws-1")

    html = render_click(view, "workflow:run", %{"command-id" => command_id})
    assert html =~ "your workflow is queued"
  end

  defp seed_workspace(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: "alpha",
        user: "alice",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => id}
      })
  end

  defp write_workflow(root, name, body) do
    dir = Path.join(root, ".dev_ide/workflows")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, name), body)
  end

  defp workflow_command_id(root, workspace_id) do
    [spec] = DevIDE.Terminals.Workflows.list_specs(workspace_id)
    assert spec.path =~ root
    DevIDE.Terminals.Workflows.command_id(spec)
  end

  defp workspace_payload(conn, workspace_path) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(
      200,
      Jason.encode!(%{
        "id" => "ws-1",
        "name" => "alpha",
        "user" => "alice",
        "status" => "running",
        "type" => "v3",
        "branch" => "main",
        "path" => workspace_path
      })
    )
  end

  defp restore(k, nil), do: Application.delete_env(:dev_ide, k)
  defp restore(k, v), do: Application.put_env(:dev_ide, k, v)
end
