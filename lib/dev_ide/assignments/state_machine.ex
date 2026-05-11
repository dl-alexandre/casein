defmodule DevIDE.Assignments.StateMachine do
  @moduledoc """
  Explicit assignment state machine for orchestration-layer assignments.

  Valid lifecycle:

      requested -> queued -> claimed -> running -> completed
                                           -> failed
                                           -> abandoned
                                           -> expired

  Terminal states (`completed`, `failed`, `abandoned`, `expired`)
  never transition to another state.
  """

  @states ~w(requested queued claimed running completed failed abandoned expired)
  @terminal ~w(completed failed abandoned expired)

  def states, do: @states
  def terminal_states, do: @terminal

  def terminal?(state), do: state in @terminal

  def transition("requested", :queue), do: {:ok, "queued"}
  def transition("requested", :claim), do: {:ok, "claimed"}
  def transition("queued", :claim), do: {:ok, "claimed"}
  def transition("claimed", :started), do: {:ok, "running"}
  def transition("claimed", :completed), do: {:ok, "completed"}
  def transition("running", :completed), do: {:ok, "completed"}
  def transition("claimed", :failed), do: {:ok, "failed"}
  def transition("running", :failed), do: {:ok, "failed"}
  def transition("queued", :expired), do: {:ok, "expired"}
  def transition("claimed", :expired), do: {:ok, "expired"}
  def transition("running", :expired), do: {:ok, "expired"}
  def transition("queued", :abandoned), do: {:ok, "abandoned"}
  def transition("claimed", :abandoned), do: {:ok, "abandoned"}
  def transition("running", :abandoned), do: {:ok, "abandoned"}
  def transition(state, _event) when state in @terminal, do: {:error, :terminal}
  def transition(_state, _event), do: {:error, :invalid_transition}
end
