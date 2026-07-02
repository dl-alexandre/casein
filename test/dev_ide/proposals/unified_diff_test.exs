defmodule DevIDE.Proposals.UnifiedDiffTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Proposals.UnifiedDiff

  setup do
    root = Path.join(System.tmp_dir!(), "ud-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "a.ex"]), "")
    File.write!(Path.join(root, "README.md"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "parses single-file modify diff", %{root: root} do
    diff = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1 +1 @@
    -old
    +new
    """

    assert {:ok, [%{path: "lib/a.ex", kind: :modify}]} = UnifiedDiff.parse(diff, root)
  end

  test "parses multi-file diff", %{root: root} do
    diff = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1 +1 @@
    -old
    +new
    --- a/README.md
    +++ b/README.md
    @@ -1 +1 @@
    -x
    +y
    """

    {:ok, changes} = UnifiedDiff.parse(diff, root)
    paths = Enum.map(changes, & &1.path) |> Enum.sort()
    assert paths == ["README.md", "lib/a.ex"]
  end

  test "/dev/null on the minus side is :add", %{root: root} do
    File.write!(Path.join(root, "new.txt"), "")

    diff = """
    --- /dev/null
    +++ b/new.txt
    @@ -0,0 +1 @@
    +hello
    """

    assert {:ok, [%{path: "new.txt", kind: :add}]} = UnifiedDiff.parse(diff, root)
  end

  test "/dev/null on the plus side is :delete", %{root: root} do
    diff = """
    --- a/lib/a.ex
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    """

    assert {:ok, [%{path: "lib/a.ex", kind: :delete}]} = UnifiedDiff.parse(diff, root)
  end

  test "rejects path traversal in diff header", %{root: root} do
    diff = """
    --- a/../../etc/passwd
    +++ b/../../etc/passwd
    @@ -1 +1 @@
    -x
    +y
    """

    assert {:error, :invalid_path} = UnifiedDiff.parse(diff, root)
  end

  test "no headers returns :no_headers", %{root: root} do
    assert {:error, :no_headers} = UnifiedDiff.parse("not a diff at all\n", root)
  end
end
