defmodule Casein.Scripts.CleanupAgentWorktreesDetachedHeadTest do
  @moduledoc """
  A detached HEAD is not evidence of unpushed work.

  `cleanup-agent-worktrees.sh` used `@{u}` to decide whether a worktree was
  fully published. A detached HEAD has no upstream by definition, so the script
  kept it forever with "no upstream — may hold unpushed work". Detaching is
  routine here: verifying a merge by checking out `origin/master` leaves the
  worktree detached, and it then pinned disk indefinitely while holding nothing.

  The replacement asks the question that matters — is every commit reachable from
  HEAD already on some remote (`rev-list HEAD --not --remotes`) — which still errs
  toward keeping, since a squash-merged commit reads as unpushed. For a deleter,
  erring toward keeping is correct.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/cleanup-agent-worktrees.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "cleanup-detached-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    primary = Path.join(root, "primary")
    wt_root = Path.join(root, "worktrees")
    File.mkdir_p!(wt_root)

    git!(["init", "--bare", "--initial-branch=master", origin], root_of(root))

    git!(["clone", origin, primary], root_of(root))
    git!(["config", "user.email", "t@example.test"], primary)
    git!(["config", "user.name", "T"], primary)
    File.write!(Path.join(primary, "a.txt"), "one\n")
    git!(["add", "a.txt"], primary)
    git!(["commit", "-m", "one"], primary)
    git!(["push", "origin", "master"], primary)

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, primary: primary, wt_root: wt_root}
  end

  test "a detached HEAD whose commits are all on a remote is removable", ctx do
    wt = Path.join(ctx.wt_root, "agent-detached-published")
    git!(["worktree", "add", "--detach", wt, "origin/master"], ctx.primary)

    out = run(ctx)

    assert out =~ "agent-detached-published",
           "the worktree should appear in the plan"

    refute out =~ ~r/keep\s+agent-detached-published/,
           """
           A detached HEAD sitting exactly on origin/master holds nothing. Keeping
           it is the false positive this change fixes.
           Output:
           #{out}
           """

    assert out =~ ~r/would remove\s+agent-detached-published/
  end

  test "a detached HEAD with a commit on no remote is kept", ctx do
    wt = Path.join(ctx.wt_root, "agent-detached-unpushed")
    git!(["worktree", "add", "--detach", wt, "origin/master"], ctx.primary)
    git!(["config", "user.email", "t@example.test"], wt)
    git!(["config", "user.name", "T"], wt)
    File.write!(Path.join(wt, "b.txt"), "local only\n")
    git!(["add", "b.txt"], wt)
    git!(["commit", "-m", "local only"], wt)

    out = run(ctx)

    assert out =~ ~r/keep\s+agent-detached-unpushed/,
           """
           A detached HEAD carrying a commit that exists on no remote MUST be kept —
           this is the case the original conservatism existed for, and it must not
           regress while fixing the false positive.
           Output:
           #{out}
           """

    assert out =~ "unpushed commit", "the reason should name what is actually wrong"
  end

  test "a normal branch tracking its upstream is still removable", ctx do
    wt = Path.join(ctx.wt_root, "agent-tracked-clean")
    git!(["worktree", "add", "-b", "feature/tracked", wt, "origin/master"], ctx.primary)
    git!(["push", "-u", "origin", "feature/tracked"], wt)

    out = run(ctx)
    assert out =~ ~r/would remove\s+agent-tracked-clean/, out
  end

  test "a branch with unpushed commits is still kept", ctx do
    wt = Path.join(ctx.wt_root, "agent-tracked-ahead")
    git!(["worktree", "add", "-b", "feature/ahead", wt, "origin/master"], ctx.primary)
    git!(["push", "-u", "origin", "feature/ahead"], wt)
    git!(["config", "user.email", "t@example.test"], wt)
    git!(["config", "user.name", "T"], wt)
    File.write!(Path.join(wt, "c.txt"), "ahead\n")
    git!(["add", "c.txt"], wt)
    git!(["commit", "-m", "ahead"], wt)

    out = run(ctx)
    assert out =~ ~r/keep\s+agent-tracked-ahead/, out
    assert out =~ "unpushed commit"
  end

  test "an uncommitted change still keeps the worktree regardless of HEAD state", ctx do
    wt = Path.join(ctx.wt_root, "agent-detached-dirty")
    git!(["worktree", "add", "--detach", wt, "origin/master"], ctx.primary)
    File.write!(Path.join(wt, "scratch.txt"), "uncommitted\n")

    out = run(ctx)
    assert out =~ ~r/keep\s+agent-detached-dirty/, out
    assert out =~ "dirty"
  end

  defp run(ctx) do
    {out, _status} =
      System.cmd("bash", [@script],
        env: [
          {"CASEIN_AGENT_WORKTREE_ROOT", ctx.wt_root},
          {"CASEIN_CHECKOUT", ctx.primary},
          {"TMUX", ""}
        ],
        cd: ctx.primary,
        stderr_to_stdout: true
      )

    out
  end

  defp root_of(root) do
    File.mkdir_p!(root)
    root
  end

  defp git!(args, cd) do
    {out, status} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed in #{cd}:\n#{out}"
    out
  end
end
