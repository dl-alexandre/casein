defmodule Scripts.DeployHandoffAncestorTest do
  @moduledoc """
  The deploy handoff used to reject any revision that was not the *tip* of
  origin/master. Since the poller's gate runs 11-15 minutes and several agents
  merge PRs per hour on this box, a branch that advanced during the build made a
  perfectly durable artifact fail its own activation (observed 2026-08-04: PR
  #596 passed the gate, then lost the handoff to PR #589 merging mid-build).

  These tests pin the two helpers that let an *ancestor* through while a
  revision genuinely absent from the branch still fails.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/deploy-devbox-release.sh", __DIR__)

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "deploy-handoff-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "casein_failing_deploy_checks" do
    test "prints nothing when every check passed" do
      assert failing(~s({"ok":true,"checks":{"socket_exists":true,"caddy":{"ok":true}}})) == []
    end

    test "names only the drift check when it alone failed" do
      json = ~s({"checks":{"socket_exists":true,"deploy_revision_current":false}})
      assert failing(json) == ["deploy_revision_current"]
    end

    # The ancestor escape hatch must not paper over a real activation problem,
    # so anything failing alongside drift has to keep the handoff red.
    test "names every failing check when more than drift is broken" do
      json =
        ~s({"checks":{"deploy_revision_current":false,"caddy_casein_upstream":{"ok":false},"socket_exists":true}})

      assert failing(json) == ["caddy_casein_upstream", "deploy_revision_current"]
    end

    test "treats unparseable or shapeless payloads as a failure, never as green" do
      assert failing("not json at all") == ["unparseable_deploy_status"]
      assert failing(~s({"checks":"nope"})) == ["unparseable_deploy_status"]
      assert failing("") == ["unparseable_deploy_status"]
    end
  end

  describe "casein_revision_on_branch_history" do
    test "accepts a revision the branch has moved past", %{tmp: tmp} do
      repo = git_fixture!(tmp)

      assert ancestor?(repo.clone, repo.behind),
             "a merged commit that is no longer the tip is still durable"

      assert ancestor?(repo.clone, repo.tip)
    end

    test "rejects a revision that never landed on the branch", %{tmp: tmp} do
      repo = git_fixture!(tmp)

      refute ancestor?(repo.clone, repo.unpushed)
    end

    test "rejects a manual label and an unusable repo", %{tmp: tmp} do
      repo = git_fixture!(tmp)

      refute ancestor?(repo.clone, "manual")
      refute ancestor?(repo.clone, "")
      refute ancestor?(Path.join(tmp, "not-a-repo"), repo.tip)
    end
  end

  # Source just the helpers out of the deploy script; the rest of it activates
  # systemd units and swaps sockets, which no test should touch.
  defp helper_source do
    src = File.read!(@script)

    for fun <- ["casein_failing_deploy_checks", "casein_revision_on_branch_history"] do
      [_, rest] = String.split(src, "\n#{fun}() {\n", parts: 2)
      [body, _] = String.split(rest, "\n}\n", parts: 2)
      "#{fun}() {\n#{body}\n}\n"
    end
    |> Enum.join("\n")
  end

  defp failing(json) do
    {out, 0} =
      System.cmd("bash", [
        "-c",
        helper_source() <> "\ncasein_failing_deploy_checks \"$1\"",
        "_",
        json
      ])

    out |> String.split("\n", trim: true)
  end

  defp ancestor?(repo, revision) do
    {_, status} =
      System.cmd(
        "bash",
        [
          "-c",
          helper_source() <>
            "\nDEPLOY_SCRIPT_SELF_DIR=\"$1\"\ncasein_revision_on_branch_history \"$2\"",
          "_",
          repo,
          revision
        ],
        stderr_to_stdout: true
      )

    status == 0
  end

  defp git_fixture!(tmp) do
    origin = Path.join(tmp, "origin.git")
    clone = Path.join(tmp, "clone")

    {_, 0} = System.cmd("git", ["init", "-q", "--bare", "-b", "master", origin], env: git_env())
    {_, 0} = System.cmd("git", ["clone", "-q", origin, clone], env: git_env())

    behind = commit!(clone, "first")
    {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "master"], env: git_env())

    tip = commit!(clone, "second")
    {_, 0} = System.cmd("git", ["-C", clone, "push", "-q", "origin", "master"], env: git_env())

    # Committed locally but never pushed — genuinely not on the branch.
    unpushed = commit!(clone, "never-pushed")

    %{clone: clone, behind: behind, tip: tip, unpushed: unpushed}
  end

  defp commit!(repo, message) do
    {_, 0} =
      System.cmd("git", ["-C", repo, "commit", "-q", "--allow-empty", "-m", message],
        env: git_env()
      )

    {sha, 0} = System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], env: git_env())
    String.trim(sha)
  end

  defp git_env do
    [
      {"GIT_AUTHOR_NAME", "t"},
      {"GIT_AUTHOR_EMAIL", "t@t"},
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"}
    ]
  end
end
