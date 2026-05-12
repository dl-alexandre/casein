defmodule DevIDE.Fleet.ExecutionStatus do
  @moduledoc """
  Shared execution-state classification for fleet execution projections.
  """

  @terminal_states [:completed, :failed, :abandoned, :expired]
  @failure_states [:failed, :abandoned, :expired]

  @spec terminal?(atom()) :: boolean()
  def terminal?(state), do: state in @terminal_states

  @spec failure?(atom()) :: boolean()
  def failure?(state), do: state in @failure_states

  @spec started?(atom()) :: boolean()
  def started?(:started), do: true
  def started?(_state), do: false
end
