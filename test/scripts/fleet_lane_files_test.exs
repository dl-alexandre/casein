defmodule Casein.Scripts.FleetLaneFilesTest do
  @moduledoc """
  #862 spawn file-set discipline: ground truth is
  `git diff --name-only origin/master...HEAD`, never window/slug labels.

  Hermetic: builds a tiny multi-worktree product repo and fakes live panes by
  pointing CASEIN_TMUX at a wrapper that prints fixed pane rows.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/fleet-lane-files.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "fleet-lane-#{System.unique_integer([:positive])}")
    origin = Path.join(root, "origin.git")
    primary = Path.join(root, "primary")
    File.mkdir_p!(root)

    git!(["init", "--bare", "--initial-branch=master", origin], root)
    git!(["clone", origin, primary], root)
    git!(["config", "user.email", "t@example.test"], primary)
    git!(["config", "user.name", "T"], primary)
    File.write!(Path.join(primary, "README"), "base\n")
    git!(["add", "README"], primary)
    git!(["commit", "-m", "base"], primary)
    git!(["push", "origin", "master"], primary)

    # Incumbent holds scripts/ only (the #248-style clear case)
    inc = Path.join(root, "incumbent")
    git!(["worktree", "add", "-b", "inc-branch", inc, "origin/master"], primary)
    git!(["config", "user.email", "t@example.test"], inc)
    git!(["config", "user.name", "T"], inc)
    File.mkdir_p!(Path.join(inc, "scripts"))
    File.write!(Path.join(inc, "scripts/foo.sh"), "echo hi\n")
    git!(["add", "scripts/foo.sh"], inc)
    git!(["commit", "-m", "inc scripts"], inc)

    # Contender holds lib/ overlapping a second contender later
    other = Path.join(root, "other")
    git!(["worktree", "add", "-b", "other-branch", other, "origin/master"], primary)
    git!(["config", "user.email", "t@example.test"], other)
    git!(["config", "user.name", "T"], other)
    File.mkdir_p!(Path.join(other, "lib/casein"))
    File.write!(Path.join(other, "lib/casein/paths.ex"), "defmodule X end\n")
    git!(["add", "lib/casein/paths.ex"], other)
    git!(["commit", "-m", "other paths"], other)

    # Fake tmux: print two panes whose cwd are the worktrees. Window names LIE
    # (label says 384-orch, files are scripts/).
    bin = Path.join(root, "bin")
    File.mkdir_p!(bin)
    tmux = Path.join(bin, "tmux")

    File.write!(
      tmux,
      """
      #!/usr/bin/env bash
      # ignore -L label; emit list-panes rows when asked
      if [[ "$*" == *list-panes* ]]; then
        printf '%s\\t%s\\t%s\\t%s\\n' \\
          "casein_test_sess" "%1" "worker-v02-384-orch-slice" "#{inc}"
        printf '%s\\t%s\\t%s\\t%s\\n' \\
          "casein_test_sess" "%2" "worker-other" "#{other}"
        exit 0
      fi
      exit 0
      """
    )

    File.chmod!(tmux, 0o755)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, primary: primary, inc: inc, other: other, bin: bin}
  end

  test "list shows committed sets and does not treat window name as ground truth", ctx do
    {out, 0} = run(ctx, ["list", "--session-prefix", "casein_"])

    assert out =~ "scripts/foo.sh"
    assert out =~ "lib/casein/paths.ex"
    # window name is displayed but must not replace the file set
    assert out =~ "worker-v02-384-orch-slice"
    assert out =~ "committed_set"
    # the lying label must not be the only signal
    assert out =~ ctx.inc
  end

  test "check CLEAR when declared set does not intersect incumbents", ctx do
    {out, 0} =
      run(ctx, [
        "check",
        "--session-prefix",
        "casein_",
        "--files",
        "lib/casein/brand_new.ex"
      ])

    assert out =~ "CLEAR"
  end

  test "check BLOCKED on intersection and prints remainder", ctx do
    {out, 1} =
      run(ctx, [
        "check",
        "--session-prefix",
        "casein_",
        "--files",
        "lib/casein/paths.ex,lib/casein/safe.ex"
      ])

    assert out =~ "BLOCKED"
    assert out =~ "lib/casein/paths.ex"
    assert out =~ "remainder"
    assert out =~ "lib/casein/safe.ex"
  end

  test "scripts-only incumbent does not block lib paths (hand-clearance case)", ctx do
    # Only the scripts incumbent would be enough; both are present — lib path
    # still CLEAR against scripts/foo.sh
    {out, 0} =
      run(ctx, [
        "check",
        "--session-prefix",
        "casein_",
        "--path",
        "lib/casein/only_newcomer.ex"
      ])

    assert out =~ "CLEAR"
  end

  defp run(ctx, args) do
    tmux = Path.join(ctx.bin, "tmux")

    env = [
      {"PATH", System.get_env("PATH", "/usr/bin:/bin")},
      {"CASEIN_TMUX_LABEL", "test-lane"},
      {"CASEIN_TMUX_BIN", tmux},
      {"CASEIN_CHECKOUT", ctx.primary}
    ]

    System.cmd("bash", [@script | args],
      env: env,
      stderr_to_stdout: true,
      cd: ctx.primary
    )
  end

  defp git!(args, cwd) do
    {_, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    :ok
  end
end
