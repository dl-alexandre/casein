defmodule Casein.AgentsReadOnlyTest do
  @moduledoc """
  Boundary guard: M8 expands the Agents behaviour with run-control callbacks
  but must not introduce write/apply/grant/prompt callbacks. The set of
  callbacks is asserted explicitly so an accidental addition fails CI.

  We also keep a static source-level guard against shelling OpenCode with
  arbitrary args from these modules — argv must come from
  `Casein.Agents.ReviewCommand` only.
  """
  use Casein.TestCase, async: true

  @allowed_callbacks ~w(detect transcripts review_commands)a
  @forbidden_callbacks ~w(apply_patch write_file grant_write send_prompt mutate_mcp)a

  @sources [
    "lib/dev_ide/agents.ex",
    "lib/dev_ide/agents/local_adapter.ex",
    "lib/dev_ide/agents/capability.ex",
    "lib/dev_ide/agents/artifact.ex",
    "lib/dev_ide/agents/review_command.ex",
    "lib/dev_ide/agents/run.ex",
    "lib/dev_ide_web/live/workspace_live/show.ex"
  ]

  test "Agents behaviour exposes exactly the allowed callbacks" do
    callbacks =
      Casein.Agents.behaviour_info(:callbacks)
      |> Enum.map(fn {name, _arity} -> name end)
      |> Enum.sort()

    assert callbacks == Enum.sort(@allowed_callbacks)
  end

  test "Agents behaviour does not expose forbidden callbacks" do
    callbacks =
      Casein.Agents.behaviour_info(:callbacks)
      |> Enum.map(fn {name, _arity} -> name end)
      |> MapSet.new()

    for cb <- @forbidden_callbacks do
      refute MapSet.member?(callbacks, cb), "forbidden callback #{cb} found"
    end
  end

  test "no agents source spawns ad-hoc opencode subcommands" do
    for rel <- @sources do
      src = File.read!(Path.expand(rel, File.cwd!()))

      refute src =~ ~r/Port\.open/, "Port.open found in #{rel}"
      refute src =~ ~r/System\.cmd\(["']opencode/, "System.cmd opencode found in #{rel}"

      # `:exec.run` is allowed (used by Commands.spawn, which Agents.Run delegates to),
      # but argv must originate from the ReviewCommand allowlist. Catch the
      # obvious "free-form argv" smell of inline opencode strings.
      refute src =~ ~r/\["opencode",\s*"(?!--version)/,
             "inline opencode argv outside ReviewCommand in #{rel}"
    end
  end

  test "ReviewCommand allowlist is the only argv source for agent runs" do
    src = File.read!("lib/dev_ide/agents/run.ex")
    # The Run server must spawn via the ReviewCommand struct (`cmd.argv`),
    # never with a literal argv list inline.
    assert src =~ "cmd.argv"
    refute src =~ ~r/Commands\.spawn\(.*,\s*\[/
  end
end
