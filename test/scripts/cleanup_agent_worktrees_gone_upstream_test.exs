defmodule Casein.Scripts.CleanupAgentWorktreesGoneUpstreamTest do
  @moduledoc """
  A branch whose remote-tracking upstream was deleted must not pin the worktree.

  `cleanup-agent-worktrees.sh` used `@{u}..HEAD` when an upstream was configured.
  After the remote branch is deleted, `rev-parse --abbrev-ref @{u}` can still
  succeed with the literal string `@{u}`, so `rev-list '@{u}..HEAD'` fails and
  the script treated the count as `1` — forever keeping a fully-published tree.

  Unpushed detection is now always `rev-list HEAD --not --remotes`.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/cleanup-agent-worktrees.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "cleanup-gone-up-#{System.unique_integer([:positive])}")
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
    %{root: root, primary: primary, wt_root: wt_root, origin: origin}
  end

  test "gone upstream with every commit still on a remote is removable", ctx do
    wt = Path.join(ctx.wt_root, "agent-gone-upstream")
    git!(["worktree", "add", "-b", "feature/gone", wt, "origin/master"], ctx.primary)
    git!(["push", "-u", "origin", "feature/gone"], wt)

    # Delete the remote branch but leave the local tracking config (gone).
    git!(["push", "origin", "--delete", "feature/gone"], ctx.primary)
    git!(["fetch", "--prune", "origin"], ctx.primary)

    # Commits are still on origin/master (branch tip was master).
    out = run(ctx)

    assert out =~ ~r/would remove\s+agent-gone-upstream/, """
    Gone upstream must not pin a fully-published worktree.
    Output:
    #{out}
    """

    refute out =~ ~r/keep\s+agent-gone-upstream/
  end

  test "gone upstream with a commit on no remote is kept", ctx do
    wt = Path.join(ctx.wt_root, "agent-gone-unpushed")
    git!(["worktree", "add", "-b", "feature/gone-local", wt, "origin/master"], ctx.primary)
    git!(["push", "-u", "origin", "feature/gone-local"], wt)
    git!(["push", "origin", "--delete", "feature/gone-local"], ctx.primary)
    git!(["fetch", "--prune", "origin"], ctx.primary)

    git!(["config", "user.email", "t@example.test"], wt)
    git!(["config", "user.name", "T"], wt)
    File.write!(Path.join(wt, "local.txt"), "only here\n")
    git!(["add", "local.txt"], wt)
    git!(["commit", "-m", "local only"], wt)

    out = run(ctx)
    assert out =~ ~r/keep\s+agent-gone-unpushed/, out
    assert out =~ "unpushed commit", out
  end

  test "noise-only dirt (.cursor) does not keep a published worktree", ctx do
    wt = Path.join(ctx.wt_root, "agent-noise-dirty")
    git!(["worktree", "add", "--detach", wt, "origin/master"], ctx.primary)
    File.mkdir_p!(Path.join(wt, ".cursor"))
    File.write!(Path.join(wt, ".cursor/mcp.json"), "{}\n")
    File.write!(Path.join(wt, "WORKER_BRIEF.md"), "brief\n")

    out = run(ctx)
    assert out =~ ~r/would remove\s+agent-noise-dirty/, out
    refute out =~ ~r/keep\s+agent-noise-dirty/
  end

  test "real dirt still keeps the worktree", ctx do
    wt = Path.join(ctx.wt_root, "agent-real-dirty")
    git!(["worktree", "add", "--detach", wt, "origin/master"], ctx.primary)
    File.write!(Path.join(wt, "product.ex"), "defmodule X do end\n")

    out = run(ctx)
    assert out =~ ~r/keep\s+agent-real-dirty/, out
    assert out =~ "dirty", out
  end

  test "merged branch is deleted after worktree remove", ctx do
    wt = Path.join(ctx.wt_root, "agent-merged-branch")
    git!(["worktree", "add", "-b", "feature/merged-del", wt, "origin/master"], ctx.primary)
    git!(["push", "-u", "origin", "feature/merged-del"], wt)

    out = run(ctx, ["--apply"])
    assert out =~ "removed agent-merged-branch", out
    assert out =~ "branch-deleted  feature/merged-del", out
    refute File.dir?(wt)

    branches = git!(["branch"], ctx.primary)
    refute branches =~ "feature/merged-del"
  end

  test "unmerged unique branch is kept after worktree remove", ctx do
    wt = Path.join(ctx.wt_root, "agent-unique-branch")
    git!(["worktree", "add", "-b", "feature/unique-keep", wt, "origin/master"], ctx.primary)
    git!(["config", "user.email", "t@example.test"], wt)
    git!(["config", "user.name", "T"], wt)
    File.write!(Path.join(wt, "unique.txt"), "unique\n")
    git!(["add", "unique.txt"], wt)
    git!(["commit", "-m", "unique"], wt)
    git!(["push", "-u", "origin", "feature/unique-keep"], wt)

    out = run(ctx, ["--apply"])
    assert out =~ "removed agent-unique-branch", out
    assert out =~ "branch-kept     feature/unique-keep", out
    refute File.dir?(wt)

    branches = git!(["branch"], ctx.primary)
    assert branches =~ "feature/unique-keep"
  end

  defp run(ctx, args \\ []) do
    {out, _status} =
      System.cmd("bash", [@script | args],
        env: [
          {"CASEIN_AGENT_WORKTREE_ROOT", ctx.wt_root},
          {"CASEIN_CHECKOUT", ctx.primary},
          {"TMUX", ""},
          {"CASEIN_TMUX_LABEL", System.get_env("CASEIN_TMUX_LABEL") || "casein"}
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
