defmodule Casein.Commands.Allowlist do
  @moduledoc """
  Static command allowlist ids → argv.

  Extracted from `Casein.Commands` so palette and other read-only callers
  can enumerate ids without pulling in the command execution graph.
  """

  @doc "Map of allowlist id → argv. Stable for tests."
  defdelegate all(), to: ExecCtl.Allowlist

  defdelegate allowed?(id), to: ExecCtl.Allowlist
  defdelegate argv_for(id), to: ExecCtl.Allowlist
end
