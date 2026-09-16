defmodule Casein.Worktrees.UnpushedAuditTest do
  use ExUnit.Case, async: true

  alias Casein.Worktrees.UnpushedAudit

  # Canned git output per worktree path, so the shapes that matter are
  # reproducible without building real repositories.
  defp runner(specs) do
    fn path, args ->
      spec = Map.fetch!(specs, path)

      case args do
        ["rev-parse", "--abbrev-ref", "HEAD"] -> {spec.branch <> "\n", 0}
        ["rev-parse", "HEAD"] -> {spec.sha <> "\n", 0}
        ["rev-list", "--count", "HEAD", "--not", "--remotes=origin"] -> {"#{spec.ahead}\n", 0}
        ["status", "--porcelain"] -> {spec.status, 0}
      end
    end
  end

  defp audit(path, spec, at_risk? \\ true) do
    UnpushedAudit.audit_one(path, at_risk?, runner: runner(%{path => spec}))
  end

  describe "verdict/1" do
    test "unpushed commits on a detached HEAD are unrecoverable" do
      # No branch means no ref survives the directory; this outranks everything.
      assert UnpushedAudit.verdict(%{detached?: true, unpushed: 3, dirty?: false}) ==
               :unrecoverable
    end

    test "unpushed commits on a branch are recoverable but exposed" do
      assert UnpushedAudit.verdict(%{detached?: false, unpushed: 3, dirty?: false}) == :unpushed
    end

    test "a detached HEAD with everything pushed is not unrecoverable" do
      assert UnpushedAudit.verdict(%{detached?: true, unpushed: 0, dirty?: false}) == :clean
    end

    test "a dirty tree with nothing unpushed is uncommitted, not unpushed" do
      assert UnpushedAudit.verdict(%{detached?: false, unpushed: 0, dirty?: true}) == :uncommitted
    end

    test "on origin and clean is clean" do
      assert UnpushedAudit.verdict(%{detached?: false, unpushed: 0, dirty?: false}) == :clean
    end
  end

  describe "audit_one/3" do
    test "reads the branch, sha, unpushed count and dirtiness" do
      spec = %{branch: "feat/thing", sha: "abc1234", ahead: 2, status: " M lib/a.ex\n"}

      assert %{
               branch: "feat/thing",
               detached?: false,
               head_sha: "abc1234",
               unpushed: 2,
               dirty?: true,
               verdict: :unpushed
             } = audit("/tmp/wt/a", spec)
    end

    test "treats a HEAD branch name as detached and reports no branch" do
      spec = %{branch: "HEAD", sha: "deadbee", ahead: 1, status: ""}

      assert %{detached?: true, branch: nil, head_sha: "deadbee", verdict: :unrecoverable} =
               audit("/tmp/wt/b", spec)
    end

    test "a renamed branch is still found, because the check never reads the name" do
      # The directory says one thing and the branch another. `--not
      # --remotes=origin` does not care, which is the point.
      spec = %{branch: "some/other-name", sha: "c0ffee1", ahead: 4, status: ""}

      assert %{unpushed: 4, verdict: :unpushed} = audit("/tmp/wt/wt-original-name", spec)
    end

    test "a clean tree fully on origin is clean" do
      spec = %{branch: "main", sha: "1111111", ahead: 0, status: ""}

      assert %{unpushed: 0, dirty?: false, verdict: :clean} = audit("/tmp/wt/c", spec)
    end

    test "a git call that fails is read as nothing unpushed, not as a crash" do
      # A directory that is not a checkout must not take the whole sweep down;
      # it simply has nothing to report.
      runner = fn _path, _args -> {"fatal: not a git repository", 128} end

      assert %{unpushed: 0, branch: nil, detached?: true, verdict: :clean} =
               UnpushedAudit.audit_one("/tmp/wt/d", true, runner: runner)
    end
  end

  describe "exposed/1 and audit/1" do
    test "orders unrecoverable first, then unpushed, then uncommitted" do
      entries = [
        %{verdict: :uncommitted, at_risk?: true, unpushed: 0, path: "c"},
        %{verdict: :clean, at_risk?: true, unpushed: 0, path: "d"},
        %{verdict: :unrecoverable, at_risk?: true, unpushed: 1, path: "a"},
        %{verdict: :unpushed, at_risk?: true, unpushed: 9, path: "b"}
      ]

      assert Enum.map(UnpushedAudit.exposed(entries), & &1.path) == ~w(a b c)
    end

    test "a worktree on a swept root outranks the same verdict on a safe one" do
      entries = [
        %{verdict: :unpushed, at_risk?: false, unpushed: 5, path: "safe"},
        %{verdict: :unpushed, at_risk?: true, unpushed: 1, path: "swept"}
      ]

      assert Enum.map(UnpushedAudit.exposed(entries), & &1.path) == ~w(swept safe)
    end

    test "audit/1 walks every root and marks the swept one" do
      tmp = Path.expand(System.tmp_dir!())
      swept = Path.join(tmp, "casein-agent-worktrees")
      safe = "/data/casein-agent-worktrees"

      specs = %{
        Path.join(swept, "wt-a") => %{branch: "HEAD", sha: "aaa", ahead: 2, status: ""},
        Path.join(safe, "wt-b") => %{branch: "feat/b", sha: "bbb", ahead: 0, status: ""}
      }

      lister = fn
        ^swept -> [Path.join(swept, "wt-a")]
        ^safe -> [Path.join(safe, "wt-b")]
      end

      entries =
        UnpushedAudit.audit(roots: [swept, safe], lister: lister, runner: runner(specs))

      assert [%{at_risk?: true, verdict: :unrecoverable}, %{at_risk?: false, verdict: :clean}] =
               entries
    end
  end

  describe "at_risk?/1" do
    test "a root under the OS temp dir is swept" do
      assert UnpushedAudit.at_risk?(Path.join(System.tmp_dir!(), "casein-agent-worktrees"))
    end

    test "a root outside it is not" do
      refute UnpushedAudit.at_risk?("/data/casein-agent-worktrees")
    end

    test "a sibling that merely shares the prefix is not swept" do
      # `/tmpfoo` starts with `/tmp` as a string but is not inside it.
      refute UnpushedAudit.at_risk?(Path.expand(System.tmp_dir!()) <> "-elsewhere")
    end
  end
end
