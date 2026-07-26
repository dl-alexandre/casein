defmodule Casein.Workspaces.ScratchTest do
  use Casein.TestCase, async: false

  alias Casein.Workspace
  alias Casein.Workspaces
  alias Casein.Workspaces.Scratch

  setup do
    prev_home = Application.get_env(:casein, :home_workspace_path)

    on_exit(fn ->
      restore(:home_workspace_path, prev_home)
    end)

    :ok
  end

  test "id/0 is the sentinel string" do
    assert Scratch.id() == "__scratch__"
  end

  test "scratch?/1 accepts the id string and workspace structs" do
    assert Scratch.scratch?("__scratch__")
    assert Scratch.scratch?(%Workspace{id: "__scratch__"})
    assert Scratch.scratch?(%Workspace{id: "other", metadata: %{scratch: true}})
    refute Scratch.scratch?("ws-1")
    refute Scratch.scratch?(%Workspace{id: "ws-1"})
    refute Scratch.scratch?(nil)
  end

  test "workspace/0 builds a synthetic running workspace rooted at home" do
    home = Path.join(System.tmp_dir!(), "casein-scratch-home-#{System.unique_integer()}")
    File.mkdir_p!(home)
    Application.put_env(:casein, :home_workspace_path, home)

    on_exit(fn -> File.rm_rf(home) end)

    ws = Scratch.workspace()

    assert ws.id == "__scratch__"
    assert ws.name == "__scratch__"
    assert ws.user == nil
    assert ws.branch == nil
    assert ws.status == :running
    assert ws.path == Path.expand(home)
    assert ws.metadata == %{scratch: true}
  end

  test "workspace/0 falls back to $HOME when home_workspace_path is unset" do
    Application.delete_env(:casein, :home_workspace_path)
    expected = System.get_env("HOME") || System.user_home!()

    ws = Scratch.workspace()
    assert ws.path == Path.expand(expected)
  end

  test "Workspaces.get/2 resolves the scratch sentinel without source lookup" do
    home = Path.join(System.tmp_dir!(), "casein-scratch-get-#{System.unique_integer()}")
    File.mkdir_p!(home)
    Application.put_env(:casein, :home_workspace_path, home)

    on_exit(fn -> File.rm_rf(home) end)

    assert {:ok, ws} = Workspaces.get("__scratch__")
    assert Scratch.scratch?(ws)
    assert ws.path == Path.expand(home)
  end

  test "safe_host_loc/1 and safe_host_path/1 return the home directory for scratch" do
    home = Path.join(System.tmp_dir!(), "casein-scratch-loc-#{System.unique_integer()}")
    File.mkdir_p!(home)
    Application.put_env(:casein, :home_workspace_path, home)

    on_exit(fn -> File.rm_rf(home) end)

    ws = Scratch.workspace()
    expanded = Path.expand(home)

    assert Workspaces.safe_host_path(ws) == {:ok, expanded}
    assert Workspaces.safe_host_loc(ws) == {:ok, {:local, expanded}}
  end

  test "viewer_can_access_workspace? allows any authenticated viewer for scratch" do
    ws = Scratch.workspace()
    bob = %{id: "bob", email: "bob@example.com"}

    assert Workspaces.viewer_can_access_workspace?(ws, bob)
  end

  defp restore(key, nil), do: Application.delete_env(:casein, key)
  defp restore(key, value), do: Application.put_env(:casein, key, value)
end
