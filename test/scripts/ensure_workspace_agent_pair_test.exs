defmodule Scripts.EnsureWorkspaceAgentPairTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/ensure-workspace-agent-pair.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  # Exercise skill_source_dir/0 in isolation.
  #
  # The candidate list and the deployed-revision lookup are stubbed so the test
  # never depends on what happens to exist on the box: the point is the
  # PRECEDENCE, not the paths.
  defp resolve(opts) do
    root = Keyword.fetch!(opts, :root)
    candidates = Keyword.get(opts, :candidates, [])
    deployed = Keyword.get(opts, :deployed, "")
    override = Keyword.get(opts, :override)

    script = """
    set -uo pipefail
    ROOT=#{sh(root)}
    #{if override, do: "export CASEIN_SKILL_SRC=#{sh(override)}", else: ""}
    log() { :; }
    deployed_revision() { printf '%s\\n' #{sh(deployed)}; }
    skill_source_candidates() { printf '%s\\n' #{Enum.map_join(candidates, " ", &sh/1)}; }
    # Real implementations of the two helpers we are not stubbing.
    eval "$(awk '/^skill_src_revision\\(\\) \\{$/,/^\\}$/' #{sh(@script)})"
    eval "$(awk '/^has_skills\\(\\) \\{$/,/^\\}$/' #{sh(@script)})"
    eval "$(awk '/^skill_source_dir\\(\\) \\{$/,/^\\}$/' #{sh(@script)})"
    skill_source_dir
    """

    {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)
    String.trim(out)
  end

  defp sh(path), do: "'" <> String.replace(to_string(path), "'", ~S('\'')) <> "'"

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "pair-src-#{name}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  # A git checkout carrying a .claude/skills tree, returning {skills_dir, head_sha}.
  defp checkout(name) do
    repo = tmp(name)
    File.mkdir_p!(Path.join([repo, ".claude", "skills", "preview-ui-walk"]))
    File.write!(Path.join(repo, "f"), "x\n")
    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end
    git.(["init"])
    git.(["add", "."])
    git.(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", name])
    {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repo)
    {Path.join([repo, ".claude", "skills"]), String.trim(sha)}
  end

  describe "skill_source_dir precedence" do
    test "a candidate at the DEPLOYED revision wins over a working checkout listed first" do
      # The regression: /data/workspaces/dalexandre/dev_ide is a working
      # checkout on whatever branch someone is using, and it outranked the
      # deploy-build. Pairing after a deploy therefore staged whatever that
      # branch contained — silently, with nothing in the log to say so.
      {working, _} = checkout("working")
      {deployed, sha} = checkout("deployed")

      assert resolve(
               root: tmp("no-skills"),
               candidates: [working, deployed],
               deployed: sha
             ) == deployed
    end

    test "an unknown deployed revision preserves the historical order" do
      {working, _} = checkout("working")
      {deployed, _} = checkout("deployed")

      assert resolve(root: tmp("no-skills"), candidates: [working, deployed], deployed: "") ==
               working
    end

    test "no candidate matching the deployed revision preserves the historical order" do
      {working, _} = checkout("working")
      {deployed, _} = checkout("deployed")

      assert resolve(
               root: tmp("no-skills"),
               candidates: [working, deployed],
               deployed: String.duplicate("d", 40)
             ) == working
    end

    test "ROOT with skills still wins — running from a checkout is deliberate" do
      {root_skills, _} = checkout("root")
      {deployed, sha} = checkout("deployed")
      root = root_skills |> Path.dirname() |> Path.dirname()

      assert resolve(root: root, candidates: [deployed], deployed: sha) == root_skills
    end

    test "CASEIN_SKILL_SRC overrides everything" do
      {deployed, sha} = checkout("deployed")
      override = tmp("override")

      assert resolve(
               root: tmp("no-skills"),
               candidates: [deployed],
               deployed: sha,
               override: override
             ) == override
    end

    test "falls back to ROOT when no candidate carries skills" do
      root = tmp("no-skills")

      assert resolve(root: root, candidates: [tmp("empty")], deployed: "") ==
               Path.join([root, ".claude", "skills"])
    end
  end
end
