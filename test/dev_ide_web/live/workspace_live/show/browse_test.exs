defmodule DevIdeWeb.WorkspaceLive.Show.BrowseTest do
  use ExUnit.Case, async: false

  alias DevIdeWeb.WorkspaceLive.Show.Browse

  setup do
    root = Path.join(System.tmp_dir!(), "devide-browse-#{System.unique_integer([:positive])}")
    alice = Path.join(root, "alice")
    bob = Path.join(root, "bob")
    nested = Path.join(alice, "project")
    File.mkdir_p!(nested)
    File.mkdir_p!(bob)
    File.write!(Path.join(root, "not-a-dir.txt"), "x")
    File.mkdir_p!(Path.join(root, ".hidden"))

    prev_root = Application.get_env(:dev_ide, :lan_path_root)
    prev_workspaces_root = Application.get_env(:dev_ide, :workspaces_root)
    prev_forward = Application.get_env(:dev_ide, :forward_auth)

    Application.put_env(:dev_ide, :lan_path_root, root)
    Application.put_env(:dev_ide, :workspaces_root, root)

    on_exit(fn ->
      File.rm_rf(root)
      restore(:lan_path_root, prev_root)
      restore(:workspaces_root, prev_workspaces_root)
      restore(:forward_auth, prev_forward)
    end)

    {:ok, root: root, alice: alice, bob: bob, nested: nested}
  end

  test "browse_tier/1 returns a collapsed Browse root by default", %{root: root} do
    [node] = Browse.browse_tier(root: root, expanded_dirs: MapSet.new())

    assert node.kind == :browse_root
    assert node.label == "Browse"
    assert node.rel == ""
    refute node.expanded?
    assert node.children == nil
    assert node.flat_session? == false
  end

  test "browse_tier/1 expands root children and nested expanded dirs", %{
    root: root,
    alice: alice
  } do
    expanded = MapSet.new(["", "alice"])

    [node] =
      Browse.browse_tier(
        root: root,
        expanded_dirs: expanded,
        restricted?: false
      )

    assert node.expanded?
    assert is_list(node.children)
    names = Enum.map(node.children, & &1.label)
    assert "alice" in names
    assert "bob" in names
    refute Enum.any?(names, &String.starts_with?(&1, "."))

    alice_node = Enum.find(node.children, &(&1.rel == "alice"))
    assert alice_node.kind == :browse_dir
    assert alice_node.path == alice
    assert alice_node.expanded?
    assert [%{label: "project", rel: "alice/project"}] = alice_node.children
  end

  test "list_entries/3 returns only directories under the root", %{root: root} do
    entries = Browse.list_entries(root, nil, restricted?: false)
    assert Enum.map(entries, & &1.name) == ["alice", "bob"]
  end

  test "dir_rel_visible?/2 allows everything when unrestricted" do
    assert Browse.dir_rel_visible?("bob/secret", restricted?: false)
  end

  test "dir_rel_visible?/2 gates restricted viewers to their identity segment", %{root: root} do
    opts = [
      root: root,
      restricted?: true,
      viewer: %{id: "alice", email: "alice@example.com"},
      workspaces: []
    ]

    assert Browse.dir_rel_visible?("alice", opts)
    assert Browse.dir_rel_visible?("alice/project", opts)
    refute Browse.dir_rel_visible?("bob", opts)
    refute Browse.dir_rel_visible?("bob/other", opts)
  end

  test "allowed_first_segments/1 includes workspace path segments", %{root: root, bob: bob} do
    segments =
      Browse.allowed_first_segments(
        root: root,
        viewer: %{id: "carol", email: "carol@example.com"},
        workspaces: [%{path: bob}]
      )

    assert "carol" in segments
    assert "bob" in segments
  end

  test "viewer_identifiers/1 includes email local-part" do
    ids = Browse.viewer_identifiers(%{id: "u1", email: "alice@example.com", username: "al"})
    assert "u1" in ids
    assert "alice@example.com" in ids
    assert "alice" in ids
    assert "al" in ids
  end

  test "restricted browse_tier hides foreign top-level dirs", %{root: root} do
    [node] =
      Browse.browse_tier(
        root: root,
        expanded_dirs: MapSet.new([""]),
        restricted?: true,
        viewer: %{id: "alice", email: "alice@example.com"},
        workspaces: []
      )

    assert Enum.map(node.children, & &1.label) == ["alice"]
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
