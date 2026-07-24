defmodule ExecCtl.Allowlist do
  @moduledoc """
  Static command allowlist ids → argv for palette and agent-safe runners.
  """

  @allowlist %{
    "compile" => ["mix", "compile"],
    "test" => ["mix", "test", "--color"],
    "format" => ["mix", "format", "--check-formatted"],
    "precommit" => ["mix", "precommit"],
    "assets.build" => ["mix", "assets.build"],
    "agent" => ["agent"],
    "claude" => ["claude"],
    # Host alias for skip-permissions; Casein claude shim already defaults to that.
    "clauded" => ["claude"],
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

  @doc "Map of allowlist id → argv."
  @spec all() :: %{String.t() => [String.t()]}
  def all, do: @allowlist

  @spec allowed?(String.t()) :: boolean()
  def allowed?(id), do: Map.has_key?(@allowlist, id)

  @spec argv_for(String.t()) :: {:ok, [String.t()]} | :error
  def argv_for(id), do: Map.fetch(@allowlist, id)
end
