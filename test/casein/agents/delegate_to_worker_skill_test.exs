defmodule Casein.Agents.DelegateToWorkerSkillTest do
  use ExUnit.Case, async: true

  @skill Path.expand("../../../.claude/skills/delegate-to-worker/SKILL.md", __DIR__)
  @mcp_doc Path.expand("../../../docs/terminal_mcp.md", __DIR__)

  test "delegate-to-worker leads with worker_launch and forbids spawn archaeology" do
    skill = File.read!(@skill)
    section3 = section_after(skill, "## 3. Acquire a worker pane")

    assert section3 =~ "Step one is the `worker_launch` MCP tool"
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
