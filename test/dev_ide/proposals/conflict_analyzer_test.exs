defmodule DevIDE.Proposals.ConflictAnalyzerTest do
  # async: true is safe because the git adapter is swapped per-process via
  # DevIDE.ProcessEnv (see use_workspace_diff/1) instead of global Application
  # env, and each test works in its own unique temp root.
  use DevIDE.TestCase, async: true

  alias DevIDE.Proposals.{ConflictAnalyzer, Proposal, UnifiedDiff, Hunk}

  setup do
    root = Path.join(System.tmp_dir!(), "ca-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "a.ex"]), "")
    File.write!(Path.join(root, "README.md"), "")

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  defp mock_module(diff) do
    name = :"DevIDE.Test.GitStub#{System.unique_integer([:positive])}"

    contents =
      quote do
        @behaviour DevIDE.Git.Adapter
        @impl true
        def branch(_), do: {:ok, "main"}
        @impl true
        def status_short(_), do: {:ok, []}
        @impl true
        def diff(_, _), do: {:ok, ""}
        @impl true
        def diff_all(_), do: {:ok, unquote(diff)}
      end

    {:module, mod, _, _} = Module.create(name, contents, Macro.Env.location(__ENV__))
    mod
  end

  defp use_workspace_diff(diff) do
    DevIDE.ProcessEnv.put(:git_adapter, mock_module(diff))
  end

  defp proposal(diff) do
    %Proposal{
      rel_path: "fix.diff",
      name: "fix.diff",
      size: byte_size(diff),
      parser: :unified_diff,
      status: :parsed,
      changes: [],
      diff: diff
    }
  end

  test "Hunk.overlap?/2 catches edge cases" do
    assert Hunk.overlap?({1, 3}, {2, 1})
    assert Hunk.overlap?({1, 3}, {3, 1})
    refute Hunk.overlap?({1, 3}, {4, 1})
    # zero-count ranges still occupy a line
    assert Hunk.overlap?({5, 0}, {5, 0})
  end

  test "parse_with_hunks extracts hunk ranges", %{root: root} do
    diff = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -10,3 +10,4 @@ ctx
    -old
    +new1
    +new2
    @@ -100 +101 @@
    -x
    +y
    """

    {:ok, [change]} = UnifiedDiff.parse_with_hunks(diff, root)
    assert change.path == "lib/a.ex"
    assert length(change.hunks) == 2

    [h1, h2] = change.hunks
    assert h1.old_range == {10, 3}
    assert h1.new_range == {10, 4}
    assert h2.old_range == {100, 1}
    assert h2.new_range == {101, 1}
  end

  test "clean: workspace has no overlap with proposal", %{root: root} do
    use_workspace_diff("")

    diff = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1,1 +1,1 @@
    -old
    +new
    """

    a = ConflictAnalyzer.analyze(root, proposal(diff))
    assert a.risk == :clean
    assert a.overlapping_files == []
  end

  test "overlap: same file but different hunk ranges", %{root: root} do
    use_workspace_diff("""
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1,1 +1,1 @@
    -ws-old
    +ws-new
    """)

    proposal_diff = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -100,1 +100,1 @@
    -p-old
    +p-new
    """

    a = ConflictAnalyzer.analyze(root, proposal(proposal_diff))
    assert a.risk == :overlap
    assert a.overlapping_files == ["lib/a.ex"]
  end

  test "conflict: hunk ranges overlap on the same file", %{root: root} do
    use_workspace_diff("""
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -10,3 +10,3 @@
    -ws
    +ws
    """)

    proposal_diff = """
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -11,1 +11,1 @@
    -p
    +p
    """

    a = ConflictAnalyzer.analyze(root, proposal(proposal_diff))
    assert a.risk == :conflict
    [file] = a.files
    assert file.status == :conflict
    refute file.hunks == []
  end

  test "delete proposal against changed file is :conflict", %{root: root} do
    use_workspace_diff("""
    --- a/lib/a.ex
    +++ b/lib/a.ex
    @@ -1 +1 @@
    -ws
    +ws-new
    """)

    proposal_diff = """
    --- a/lib/a.ex
    +++ /dev/null
    @@ -1 +0,0 @@
    -gone
    """

    a = ConflictAnalyzer.analyze(root, proposal(proposal_diff))
    assert a.risk == :conflict
    [file] = a.files
    assert file.kind == :delete
    assert file.status == :conflict
  end

  test "invalid proposal yields :invalid", %{root: root} do
    use_workspace_diff("")

    invalid = %Proposal{
      rel_path: "bad.diff",
      name: "bad.diff",
      parser: :unified_diff,
      status: :invalid,
      diff: nil,
      error: "no headers"
    }

    a = ConflictAnalyzer.analyze(root, invalid)
    assert a.risk == :invalid
  end
end
