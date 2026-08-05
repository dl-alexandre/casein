defmodule Scripts.AgentSkillsTest do
  use ExUnit.Case, async: true

  @lib Path.expand("../../scripts/lib/agent-skills.sh", __DIR__)

  test "lib has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @lib])
  end

  # Runs agent_skills_install <src> <config> in a subshell, returning {output, status}.
  defp install(src, config, env \\ []) do
    script = """
    set -euo pipefail
    source #{@lib}
    agent_skills_install #{sh(src)} #{sh(config)}
    """

    System.cmd("bash", ["-c", script], env: env, stderr_to_stdout: true)
  end

  defp sh(path), do: "'" <> String.replace(path, "'", ~S('\'')) <> "'"

  defp tmp(name) do
    dir =
      Path.join(System.tmp_dir!(), "agent-skills-#{name}-#{System.unique_integer([:positive])}")

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    dir
  end

  # A source .claude/skills tree with infra skills (default allowlist) and a
  # project-only skill (verify) so exclusion is observable.
  defp seed_source do
    src = tmp("src")
    File.mkdir_p!(Path.join([src, "delegate-to-worker", "references"]))
    File.write!(Path.join([src, "delegate-to-worker", "SKILL.md"]), "# delegate\nv1\n")

    File.write!(
      Path.join([src, "delegate-to-worker", "references", "prompt-template.md"]),
      "tmpl\n"
    )

    File.mkdir_p!(Path.join([src, "preview-ui-walk", "references"]))
    File.write!(Path.join([src, "preview-ui-walk", "SKILL.md"]), "# walk\nv1\n")

    File.mkdir_p!(Path.join(src, "verify"))
    File.write!(Path.join([src, "verify", "SKILL.md"]), "# verify\n")
    src
  end

  test "stages the allow-listed skill into <config>/skills and excludes project-only skills" do
    src = seed_source()
    config = tmp("config")

    assert {_, 0} = install(src, config)

    assert File.read!(Path.join([config, "skills", "delegate-to-worker", "SKILL.md"])) ==
             "# delegate\nv1\n"

    assert File.exists?(
             Path.join([
               config,
               "skills",
               "delegate-to-worker",
               "references",
               "prompt-template.md"
             ])
           )

    # preview-ui-walk is host infra for product-repo agents (default allowlist).
    assert File.read!(Path.join([config, "skills", "preview-ui-walk", "SKILL.md"])) ==
             "# walk\nv1\n"

    # `verify` is not in the default allowlist — must not leak into other repos' agents.
    refute File.exists?(Path.join([config, "skills", "verify"]))
  end

  test "is idempotent and refreshes when the canonical source changes" do
    src = seed_source()
    config = tmp("config")
    dst = Path.join([config, "skills", "delegate-to-worker", "SKILL.md"])

    assert {_, 0} = install(src, config)
    assert {_, 0} = install(src, config)
    assert File.read!(dst) == "# delegate\nv1\n"

    # Canonical source moves forward -> staged copy follows.
    File.write!(Path.join([src, "delegate-to-worker", "SKILL.md"]), "# delegate\nv2\n")
    assert {_, 0} = install(src, config)
    assert File.read!(dst) == "# delegate\nv2\n"
  end

  test "CASEIN_AGENT_SKILLS=0 opts out entirely" do
    src = seed_source()
    config = tmp("config")

    assert {_, 0} = install(src, config, [{"CASEIN_AGENT_SKILLS", "0"}])
    refute File.exists?(Path.join(config, "skills"))
  end

  test "CASEIN_GLOBAL_AGENT_SKILLS overrides the allowlist" do
    src = seed_source()
    config = tmp("config")

    assert {_, 0} =
             install(src, config, [{"CASEIN_GLOBAL_AGENT_SKILLS", "delegate-to-worker verify"}])

    assert File.exists?(Path.join([config, "skills", "delegate-to-worker", "SKILL.md"]))
    assert File.exists?(Path.join([config, "skills", "verify", "SKILL.md"]))
  end

  test "prunes a retired skill name staged before markers existed" do
    src = seed_source()
    config = tmp("config")

    # A copy staged by an older launcher: no marker file, name since renamed.
    stale = Path.join([config, "skills", "delegate-to-grok"])
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "SKILL.md"), "# stale\n")

    assert {_, 0} = install(src, config)

    refute File.exists?(stale)
    assert File.exists?(Path.join([config, "skills", "delegate-to-worker", "SKILL.md"]))
  end

  test "never prunes a skill the user authored themselves" do
    src = seed_source()
    config = tmp("config")

    mine = Path.join([config, "skills", "my-own-skill"])
    File.mkdir_p!(mine)
    File.write!(Path.join(mine, "SKILL.md"), "# mine\n")

    assert {_, 0} = install(src, config)

    # Not allow-listed, not retired, and carries no marker — it is not ours.
    assert File.read!(Path.join(mine, "SKILL.md")) == "# mine\n"
  end

  test "prunes a staged copy once it leaves the allowlist" do
    src = seed_source()
    config = tmp("config")
    staged = Path.join([config, "skills", "delegate-to-worker"])

    assert {_, 0} = install(src, config)
    assert File.exists?(Path.join(staged, ".casein-staged"))

    assert {_, 0} = install(src, config, [{"CASEIN_GLOBAL_AGENT_SKILLS", "preview-ui-walk"}])

    refute File.exists?(staged)
    assert File.exists?(Path.join([config, "skills", "preview-ui-walk", "SKILL.md"]))
  end

  test "a missing source tree is a no-op, not a failure" do
    config = tmp("config")

    assert {_, 0} =
             install(
               Path.join(
                 System.tmp_dir!(),
                 "does-not-exist-#{System.unique_integer([:positive])}"
               ),
               config
             )

    refute File.exists?(Path.join(config, "skills"))
  end
end
