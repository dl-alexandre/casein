defmodule DevIDE.Commands.Allowlist do
  @moduledoc """
  Static command allowlist ids → argv.

  Extracted from `DevIDE.Commands` so palette and other read-only callers
  can enumerate ids without pulling in the command execution graph.
  """

  @allowlist %{
    "compile" => ["mix", "compile"],
    "test" => ["mix", "test", "--color"],
    "format" => ["mix", "format", "--check-formatted"],
    "precommit" => ["mix", "precommit"],
    "assets.build" => ["mix", "assets.build"],
    "agent" => ["agent"],
    "claude" => ["claude"],
    "clauded" => ["clauded"],
    "codex" => ["codex"],
    "dogfood.fail" => [
      "mix",
      "run",
      "-e",
      "IO.puts(:stderr, \"dogfood failure\"); System.halt(42)"
    ],
    "grok" => ["grok"],
    "opencode" => ["opencode"]
  }

  @doc "Map of allowlist id → argv. Stable for tests."
  def all, do: @allowlist

  def allowed?(id), do: Map.has_key?(@allowlist, id)
  def argv_for(id), do: Map.fetch(@allowlist, id)
end
