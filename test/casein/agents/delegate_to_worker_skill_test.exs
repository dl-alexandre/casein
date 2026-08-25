defmodule Casein.Agents.DelegateToWorkerSkillTest do
  use ExUnit.Case, async: true

  @skill Path.expand("../../../.claude/skills/delegate-to-worker/SKILL.md", __DIR__)
  @mcp_doc Path.expand("../../../docs/terminal_mcp.md", __DIR__)

  test "delegate-to-worker leads with jido_admit and keeps worker_launch as OpenCode fallback" do
    skill = File.read!(@skill)
    section3 = section_after(skill, "## 3. Acquire a worker")

    assert section3 =~ "jido_admit"
    assert section3 =~ "code_read|code_search|code_apply_patch|code_exec"
    assert first_index(section3, "jido_admit") < first_index(section3, "worker_launch")
    assert section3 =~ "The only supported TUI spawn path is the `worker_launch` MCP tool"
    assert first_index(section3, "worker_launch") < first_index(section3, "spawn-agent-worker.sh")

    refute section3 =~ ~r/bash ["']?\$\{CASEIN_SCRIPTS/
    refute section3 =~ ~r/bash ["']?\$CASEIN_SCRIPTS/
    refute skill =~ ~r/bash .*\$\{CASEIN_SCRIPTS\}/
    refute skill =~ ~r/bash .*\$CASEIN_SCRIPTS/

    assert skill =~ ~r/Do \*\*not\*\* `find`/
    assert skill =~ "Do not search the filesystem"

    assert skill =~ "terminal_say(to: \"pane:<worker_pane>\""
    assert skill =~ "terminal_inbox"
    assert skill =~ "without racing the TUI"
    assert skill =~ "jido_status"
    assert skill =~ "jido_cancel"
    assert skill =~ "fallback?: true"
  end

  test "prompt template documents typed CodeTools and forbids tmux on Jido" do
    template =
      File.read!(
        Path.expand(
          "../../../.claude/skills/delegate-to-worker/references/prompt-template.md",
          __DIR__
        )
      )

    assert template =~ "jido_admit"
    assert template =~ "code_apply_patch"
    assert template =~ "Forbidden: `terminal_send_*`"
    assert template =~ "fallback?: true"
  end

  test "terminal MCP docs do not teach a checkout-local spawn path" do
    doc = File.read!(@mcp_doc)

    assert doc =~ "worker_launch"
    refute doc =~ "/data/workspaces/dalexandre/casein/scripts/spawn-agent-worker.sh"
    refute doc =~ ~r/bash \$\{CASEIN_SCRIPTS/
  end

  defp section_after(text, heading) do
    case String.split(text, heading, parts: 2) do
      [_before, rest] ->
        rest
        |> String.split(~r/\n## /, parts: 2)
        |> hd()

      _ ->
        flunk("missing heading #{inspect(heading)}")
    end
  end

  defp first_index(text, needle) do
    case :binary.match(text, needle) do
      {index, _} -> index
      :nomatch -> flunk("expected #{inspect(needle)} in spawn section")
    end
  end
end
