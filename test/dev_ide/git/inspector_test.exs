defmodule Casein.Git.InspectorTest do
  # Serial: mutates process-global Application env (:git_ctl :cache_ttl_ms).
  use Casein.TestCase, async: false

  alias Casein.Git.Inspector

  setup do
    tmp =
      Path.join(tmp_root(), "devide-git-inspector-#{System.unique_integer([:positive])}")

    main = Path.join(tmp, "main")
    worktree = Path.join(tmp, "feature-worktree")
    detached_worktree = Path.join(tmp, "detached-worktree")

    File.rm_rf!(tmp)
    File.mkdir_p!(main)

    git!(main, ["init", "--initial-branch=main"])
    git!(main, ["config", "user.name", "Test"])
    git!(main, ["config", "user.email", "test@example.com"])

    File.write!(Path.join(main, "README.md"), "# Test Repo\n")
    git!(main, ["add", "README.md"])
    git!(main, ["commit", "-m", "init"])

    git!(main, ["worktree", "add", "-b", "feature-test", worktree, "main"])
    commit_sha = git!(main, ["rev-parse", "HEAD"])
    git!(main, ["worktree", "add", "--detach", detached_worktree, commit_sha])

    on_exit(fn -> File.rm_rf!(tmp) end)

    %{main: main, worktree: worktree, detached_worktree: detached_worktree}
  end

  test "inspects normal main checkout", %{main: main} do
    assert {:ok, info} = Inspector.inspect_cwd(main)
    assert info.toplevel == main
    assert info.worktree? == false
    assert info.detached? == false
    assert info.branch == "main"
    assert info.agent == nil
    assert String.length(info.head_sha) > 0
  end

  test "inspects linked worktree", %{worktree: worktree} do
    assert {:ok, info} = Inspector.inspect_cwd(worktree)
    assert info.toplevel == worktree
    assert info.worktree? == true
    assert info.detached? == false
    assert info.branch == "feature-test"
    assert info.agent == nil
  end

  test "inspects detached HEAD worktree", %{detached_worktree: detached_worktree} do
    assert {:ok, info} = Inspector.inspect_cwd(detached_worktree)
    assert info.toplevel == detached_worktree
    assert info.worktree? == true
    assert info.detached? == true
    assert String.match?(info.branch, ~r/^[0-9a-f]{4,}$/)
    assert info.agent == nil
  end

  test "returns error for non-git directories and missing paths" do
    tmp = Path.join(tmp_root(), "devide-non-git-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    assert Inspector.inspect_cwd(tmp) == :error
    assert Inspector.inspect_cwd("/non/existent/path") == :error
  end

  test "caches results per cwd within the TTL", %{main: main} do
    prev_ctl = Application.get_env(:git_ctl, :cache_ttl_ms)
    Application.put_env(:git_ctl, :cache_ttl_ms, 60_000)
    on_exit(fn -> Application.put_env(:git_ctl, :cache_ttl_ms, prev_ctl) end)

    assert {:ok, info} = Inspector.inspect_cwd(main)
    assert info.branch == "main"

    git!(main, ["checkout", "-q", "-b", "cache-probe"])

    # Within the TTL the cached snapshot is returned, not the new branch.
    assert {:ok, cached} = Inspector.inspect_cwd(main)
    assert cached.branch == "main"

    # TTL 0 bypasses the cache and sees the mutation.
    Application.put_env(:git_ctl, :cache_ttl_ms, 0)
    assert {:ok, fresh} = Inspector.inspect_cwd(main)
    assert fresh.branch == "cache-probe"
  end

  test "infers agent from path" do
    assert Inspector.infer_agent("/home/dalexandre/.local/share/opencode/auth-refactor") ==
             "opencode"

    assert Inspector.infer_agent("/home/dalexandre/.claude/worktrees/fix-api") == "claude"
    assert Inspector.infer_agent("/tmp/grok-build-session") == "grok"
    assert Inspector.infer_agent("/tmp/codex-worktree") == "codex"
    assert Inspector.infer_agent("/home/dalexandre/dev_ide") == nil
  end

  defp git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    String.trim(output)
  end

  defp tmp_root do
    root = System.get_env("DEV_IDE_TEST_TMPDIR") || System.tmp_dir!()
    File.mkdir_p!(root)
    root
  end
end
