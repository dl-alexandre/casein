defmodule CaseinWeb.WorkspaceRoutesTest do
  use CaseinWeb.ConnCase, async: false

  alias CaseinWeb.WorkspaceRoutes

  setup do
    keys = [:forward_auth, :home_workspace_path, :lan_mode, :lan_path_root, :workspaces_root]
    previous = Map.new(keys, &{&1, Application.get_env(:dev_ide, &1)})

    root =
      Path.join(
        System.tmp_dir!(),
        "devide-workspace-routes-#{System.unique_integer([:positive])}"
      )

    project = Path.join(root, "project")

    File.mkdir_p!(project)

    Application.put_env(:dev_ide, :forward_auth, false)
    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :lan_path_root, root)
    Application.delete_env(:dev_ide, :workspaces_root)
    Application.delete_env(:dev_ide, :home_workspace_path)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:dev_ide, key)
        {key, value} -> Application.put_env(:dev_ide, key, value)
      end)

      File.rm_rf(root)
    end)

    %{project: project}
  end

  test "emits path routes only in trusted LAN mode", %{project: project} do
    workspace = %{id: "ws-project", path: project}

    assert WorkspaceRoutes.path_routes_trusted?()
    assert WorkspaceRoutes.workspace_path(workspace, "local") == "/project"

    assert WorkspaceRoutes.workspace_path(workspace, "remote") ==
             "/workspaces/ws-project?host=remote"

    Application.put_env(:dev_ide, :lan_mode, false)
    refute WorkspaceRoutes.path_routes_trusted?()
    assert WorkspaceRoutes.workspace_path(workspace, "local") == "/workspaces/ws-project"

    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :forward_auth, true)
    refute WorkspaceRoutes.path_routes_trusted?()
    assert WorkspaceRoutes.workspace_path(workspace, "local") == "/workspaces/ws-project"
  end
end
