defmodule Casein.Scripts.CleanupAgentWorktreesForeignRepoTest do
  @moduledoc """
  The agent worktree root is SHARED across repositories.

  `cleanup-agent-worktrees.sh` resolved the removing repo ONCE from the current
  directory. Every eligibility check already asked the worktree's own repo via
  `git -C`, so a worktree belonging to another repository passed all of them,
  was advertised as `would remove`, and then failed on `--apply` with
  "is not a working tree" — leaving it on disk.

  That is worse than declining: a dry run that promises cleanup it cannot
  deliver sends the operator away believing the disk was reclaimed. Observed for
  real on the devbox, where three `dalexandre-mira` worktrees sat under the
  casein worktree root and every `--apply` reported FAILED.

  The owning repo is now resolved per worktree.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/cleanup-agent-worktrees.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "cleanup-foreign-#{System.unique_integer([:positive])}")
    wt_root = Path.join(root, "worktrees")
    File.mkdir_p!(wt_root)

    ours = seed_repo(root, "ours")
    theirs = seed_repo(root, "theirs")

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, ours: ours, theirs: theirs, wt_root: wt_root}
  end

  # An origin + a clone with one pushed commit, so worktrees off it read as
  # fully published.
  defp seed_repo(root, name) do
    origin = Path.join(root, "#{name}.git")
    checkout = Path.join(root, name)
    git!(["init", "--bare", "--initial-branch=master", origin], root)
    git!(["clone", origin, checkout], root)
    git!(["config", "user.email", "t@example.test"], checkout)
    git!(["config", "user.name", "T"], checkout)
    File.write!(Path.join(checkout, "a.txt"), "one\n")
    git!(["add", "a.txt"], checkout)
    git!(["commit", "-m", "one"], checkout)
    git!(["push", "origin", "master"], checkout)
    checkout
  end

  defp git!(args, cd) do
    {out, status} = System.cmd("git", args, cd: cd, stderr_to_stdout: true)
    assert status == 0, "git #{Enum.join(args, " ")} failed:\n#{out}"
    out
  end

  # Run the sweep FROM `ours`, so `theirs` is the foreign repo.
  defp run(ctx, args \\ []) do
    {out, _status} =
      System.cmd("bash", [@script | args],
        cd: ctx.ours,
        stderr_to_stdout: true,
        env: [
          {"CASEIN_AGENT_WORKTREE_ROOT", ctx.wt_root},
          # A label that resolves to no tmux server would make --apply refuse
          # outright; point at the real one so the live-probe succeeds and the
          # temp paths simply match no pane.
          {"CASEIN_TMUX_LABEL", System.get_env("CASEIN_TMUX_LABEL") || "casein"}
        ]
      )

    out
  end

  test "a worktree owned by another repo is actually removed, not just promised", ctx do
    theirs_wt = Path.join(ctx.wt_root, "agent-foreign")
    git!(["worktree", "add", "--detach", theirs_wt, "origin/master"], ctx.theirs)

    assert run(ctx) =~ "would remove  agent-foreign"

    out = run(ctx, ["--apply"])

    refute out =~ "FAILED",
           "foreign worktree removal must not fail:\n#{out}"

    assert out =~ "removed agent-foreign"
    refute File.dir?(theirs_wt), "foreign worktree should be gone from disk"
  end

  test "the dry run names the owning repo when it is not ours", ctx do
    theirs_wt = Path.join(ctx.wt_root, "agent-foreign-labelled")
    git!(["worktree", "add", "--detach", theirs_wt, "origin/master"], ctx.theirs)

    assert run(ctx) =~ "[owner: #{ctx.theirs}]",
           "operator must be able to see the sweep reaches across repositories"
  end

  test "our own worktrees are removed without an owner label", ctx do
    ours_wt = Path.join(ctx.wt_root, "agent-ours")
    git!(["worktree", "add", "--detach", ours_wt, "origin/master"], ctx.ours)

    out = run(ctx)
    assert out =~ "would remove  agent-ours"
    refute out =~ "agent-ours  (clean, idle, pushed)  [owner:"
  end

  test "the foreign repo is pruned, so no stale worktree entry survives", ctx do
    theirs_wt = Path.join(ctx.wt_root, "agent-foreign-prune")
    git!(["worktree", "add", "--detach", theirs_wt, "origin/master"], ctx.theirs)

    run(ctx, ["--apply"])

    refute git!(["worktree", "list"], ctx.theirs) =~ "agent-foreign-prune",
           "the owning repo must not keep an administrative entry for a deleted directory"
  end

  test "a repo's MAIN worktree under the root is never removed", ctx do
    # A primary checkout that happens to live under the shared root passes every
    # eligibility check; only its identity as the repo's main worktree saves it.
    inside = seed_repo(ctx.wt_root, "agent-primary-checkout")

    out = run(ctx)
    assert out =~ "keep    agent-primary-checkout  (main worktree of its repo"
    assert File.dir?(inside)
  end
end
