defmodule DevIDE.Proposals.LocalAdapterTest do
  use DevIDE.TestCase, async: true
  alias DevIDE.Proposals.LocalAdapter

  setup do
    root = Path.join(System.tmp_dir!(), "pa-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([root, ".opencode", "proposals"]))
    File.write!(Path.join(root, "lib_a.ex"), "")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "discover lists *.diff and *.patch but ignores others", %{root: root} do
    base = Path.join([root, ".opencode", "proposals"])
    File.write!(Path.join(base, "fix.diff"), "--- a/x\n+++ b/x\n")
    File.write!(Path.join(base, "fix.patch"), "--- a/x\n+++ b/x\n")
    File.write!(Path.join(base, "notes.txt"), "ignore me")

    proposals = LocalAdapter.discover(root)
    names = Enum.map(proposals, & &1.name) |> Enum.sort()
    assert names == ["fix.diff", "fix.patch"]
  end

  test "discover does not follow symlinks escaping the root", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "po-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "leak.diff"), "--- a/x\n+++ b/x\n")
    File.ln_s!(outside, Path.join([root, ".opencode", "linked"]))
    on_exit(fn -> File.rm_rf!(outside) end)

    # The discovery dirs are an explicit list; symlinks named `linked/` aren't
    # in the discovery roots, so the leak.diff must not appear.
    proposals = LocalAdapter.discover(root)
    refute Enum.any?(proposals, &(&1.name == "leak.diff"))
  end

  test "parse returns :too_large for files over the limit", %{root: root} do
    base = Path.join([root, ".opencode", "proposals"])
    big = String.duplicate("x", 600 * 1024)
    File.write!(Path.join(base, "big.diff"), big)

    {:ok, p} = LocalAdapter.parse(root, ".opencode/proposals/big.diff")
    assert p.status == :too_large
  end

  test "parse returns :unsupported for non-diff extensions", %{root: root} do
    File.write!(Path.join(root, "weird.txt"), "data")
    {:ok, p} = LocalAdapter.parse(root, "weird.txt")
    assert p.status == :unsupported
  end

  test "parse extracts changes for a valid unified diff", %{root: root} do
    base = Path.join([root, ".opencode", "proposals"])
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "a.ex"]), "")

    File.write!(Path.join(base, "fix.diff"), """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1 +1 @@
    -old
    +new
    """)

    {:ok, p} = LocalAdapter.parse(root, ".opencode/proposals/fix.diff")
    assert p.status == :parsed
    assert [%{path: "lib/a.ex", kind: :modify}] = p.changes
  end

  test "parse refuses traversal in diff header", %{root: root} do
    base = Path.join([root, ".opencode", "proposals"])

    File.write!(Path.join(base, "bad.diff"), """
    --- a/../../etc/passwd
    +++ b/../../etc/passwd
    @@ -1 +1 @@
    -x
    +y
    """)

    {:ok, p} = LocalAdapter.parse(root, ".opencode/proposals/bad.diff")
    assert p.status == :invalid
    assert p.error =~ "traversal"
  end
end
