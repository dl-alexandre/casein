defmodule Casein.Agents.TerminalToolsOpenDiffTest do
  use Casein.DataCase, async: false

  alias Casein.Agents.MCPAudit
  alias Casein.Agents.TerminalTools
  alias Casein.Audit
  alias Casein.Inspectors.Diff

  setup do
    prev_root = Application.get_env(:casein, :workspaces_root)

    on_exit(fn ->
      restore(:workspaces_root, prev_root)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, val), do: Application.put_env(:casein, key, val)

  defp seed_workspace! do
    root = Casein.TmpWorkspace.root!("mcp-open-diff")
    path = Path.join(root, "ws")
    File.mkdir_p!(Path.join(path, "lib"))
    File.write!(Path.join(path, "lib/foo.ex"), "defmodule Foo do\nend\n")
    Application.put_env(:casein, :workspaces_root, root)
    {:ok, workspace} = Casein.Workspaces.attach_folder(path)
    {path, workspace}
  end

  test "surfaces a diff when a viewer is watching" do
    {_root, workspace} = seed_workspace!()
    :ok = Diff.subscribe(workspace.id)
    :ok = Diff.register_viewer(workspace.id)

    assert {:ok, %{status: "surfaced", workspace_id: ws_id, path: "lib/foo.ex"}} =
             TerminalTools.invoke("diff_open", %{
               "workspace_id" => workspace.id,
               "path" => "lib/foo.ex"
             })

    assert ws_id == workspace.id
    assert_receive {:surface_diff, %{path: "lib/foo.ex", workspace_id: ^ws_id}}, 200
  end

  test "is a no-op when nobody is watching" do
    {_root, workspace} = seed_workspace!()
    refute Diff.viewer_present?(workspace.id)

    assert {:ok, %{status: "no_viewer", workspace_id: ws_id}} =
             TerminalTools.invoke("diff_open", %{"workspace_id" => workspace.id})

    assert ws_id == workspace.id
  end

  test "rejects any placement argument" do
    {_root, workspace} = seed_workspace!()

    for key <- ~w(placement size position pane_id geometry focus fraction ratio) do
      assert {:error, %{error: :placement_not_allowed, rejected: rejected}} =
               TerminalTools.invoke("diff_open", %{
                 "workspace_id" => workspace.id,
                 key => "right"
               })

      assert key in rejected
    end
  end

  test "is audited as a mutating terminal tool" do
    {_root, workspace} = seed_workspace!()

    result =
      TerminalTools.invoke("diff_open", %{
        "workspace_id" => workspace.id,
        "path" => "lib/foo.ex"
      })

    assert {:ok, _} = result

    assert :ok =
             MCPAudit.record_terminal(
               "diff_open",
               %{"workspace_id" => workspace.id, "path" => "lib/foo.ex"},
               result
             )

    actions = workspace.id |> Audit.recent_for(10) |> Enum.map(& &1.action)
    assert "agent.terminal_diff_open" in actions
  end

  test "rejects paths outside the workspace root" do
    {_root, workspace} = seed_workspace!()

    assert {:error, :outside_root} =
             TerminalTools.invoke("diff_open", %{
               "workspace_id" => workspace.id,
               "path" => "/etc/passwd"
             })
  end

  test "requires workspace_id" do
    assert {:error, {:missing_argument, "workspace_id"}} =
             TerminalTools.invoke("diff_open", %{})
  end
end
