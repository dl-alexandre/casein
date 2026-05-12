defmodule DevIDE.Assignments.Status do
  @moduledoc """
  Shared assignment-state classification.

  Keep retry/requeue/clone decisions here so recovery, dossiers, and future UI
  surfaces do not grow divergent state lists.
  """

  alias DevIDE.Assignments.StateMachine

  @failure_states ~w(failed abandoned expired)

  @spec terminal?(String.t()) :: boolean()
  def terminal?(state), do: StateMachine.terminal?(state)

  @spec failure?(String.t()) :: boolean()
  def failure?(state), do: state in @failure_states

  @spec retryable?(String.t()) :: boolean()
  def retryable?("failed"), do: true
  def retryable?(_state), do: false

  @spec requeueable?(String.t()) :: boolean()
  def requeueable?("expired"), do: true
  def requeueable?(_state), do: false

  @spec cloneable?(String.t()) :: boolean()
  def cloneable?("abandoned"), do: true
  def cloneable?(_state), do: false
end
