defmodule Casein.Workspaces.HostPathIdentityTest do
  use Casein.TestCase, async: false

  alias Casein.Workspace
  alias Casein.Workspaces
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.{MemoryAdapter, WorkspaceRecord}

  @config_keys [:workspace_source, :workspaces_root, :lan_path_root, :home_workspace_path]

  setup do
    MemoryAdapter.clear()
    previous = Map.new(@config_keys, &{&1, Application.get_env(:casein, &1)})

    root =
      Path.join(System.tmp_dir!(), "casein-host-path-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    Application.put_env(:casein, :workspace_source, Casein.WorkspaceSource.Local)
    Application.put_env(:casein, :workspaces_root, root)
    Application.delete_env(:casein, :lan_path_root)
    Application.delete_env(:casein, :home_workspace_path)

    on_exit(fn ->
      MemoryAdapter.clear()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:casein, key)
        {key, value} -> Application.put_env(:casein, key, value)
      end)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp sync!(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: Path.basename(path),
        status: :running,
        path: path,
        metadata: %{}
      })
  end

  describe "State.records_for_host_paths/1" do
    test "returns one record per normalized path", %{root: root} do
      alpha = Path.join(root, "alpha")
      sync!("alpha", alpha)

      unnormalized = Path.join([root, "alpha", "..", "alpha"])

      assert %{^alpha => %WorkspaceRecord{external_id: "alpha"}} =
               State.records_for_host_paths([unnormalized, nil, ""])
    end

    test "prefers a manager identity over a folder-attach record for the same path",
         %{root: root} do
      alpha = Path.join(root, "alpha")
      sync!("folder:" <> Base.url_encode64(alpha, padding: false), alpha)
      sync!("manager-uuid", alpha)

      assert %{^alpha => %WorkspaceRecord{external_id: "manager-uuid"}} =
               State.records_for_host_paths([alpha])
    end

    test "returns an empty map with no usable input" do
      assert State.records_for_host_paths([nil, ""]) == %{}
    end
  end

  describe "Workspaces.workspace_for_host_path/1 identity" do
    test "resolves to the recorded manager identity when one matches", %{root: root} do
      alpha = Path.join(root, "alpha")
      File.mkdir_p!(alpha)
      sync!("alpha", alpha)

      assert {:ok, %Workspace{id: "alpha"}} = Workspaces.workspace_for_host_path(alpha)
    end

    test "falls back to a folder-attach id when no record matches", %{root: root} do
      beta = Path.join(root, "beta")
      File.mkdir_p!(beta)

      assert {:ok, %Workspace{id: "folder:" <> _}} = Workspaces.workspace_for_host_path(beta)
    end

    test "a folder-attach record does not hijack identity resolution", %{root: root} do
      gamma = Path.join(root, "gamma")
      File.mkdir_p!(gamma)
      sync!("folder:" <> Base.url_encode64(gamma, padding: false), gamma)

      assert {:ok, %Workspace{id: "folder:" <> _}} = Workspaces.workspace_for_host_path(gamma)
    end

    test "a stale record falls back to folder attach", %{root: root} do
      delta = Path.join(root, "delta")
      File.mkdir_p!(delta)
      # Record points at delta under an id the Local source no longer knows.
      sync!("gone-uuid", delta)

      assert {:ok, %Workspace{id: "folder:" <> _}} = Workspaces.workspace_for_host_path(delta)
    end
  end
end
