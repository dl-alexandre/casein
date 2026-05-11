defmodule DevIDE.Runners.StateMachine do
  @moduledoc """
  Explicit runner assignment state machine for protocol v1.

  Valid states:

      queued -> claimed -> running -> succeeded | failed | expired | abandoned

  A claimed assignment may also expire or be abandoned before it reports that it
  is running. Terminal states never transition to another state.
  """

  @statuses ~w(queued claimed running succeeded failed expired abandoned)
  @terminal ~w(succeeded failed expired abandoned)

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal

  def terminal?(status), do: status in @terminal

  def transition("queued", :claim), do: {:ok, "claimed"}
  def transition("claimed", :start), do: {:ok, "running"}
  def transition("claimed", :succeed), do: {:ok, "succeeded"}
  def transition("running", :succeed), do: {:ok, "succeeded"}
  def transition("claimed", :fail), do: {:ok, "failed"}
  def transition("running", :fail), do: {:ok, "failed"}
  def transition("queued", :expire), do: {:ok, "expired"}
  def transition("claimed", :expire), do: {:ok, "expired"}
  def transition("running", :expire), do: {:ok, "expired"}
  def transition("queued", :abandon), do: {:ok, "abandoned"}
  def transition("claimed", :abandon), do: {:ok, "abandoned"}
  def transition("running", :abandon), do: {:ok, "abandoned"}
  def transition(status, _event) when status in @terminal, do: {:error, :assignment_terminal}
  def transition(_status, _event), do: {:error, :invalid_transition}

  def start_event?("started"), do: true
  def start_event?("progress"), do: true
  def start_event?("stdout"), do: true
  def start_event?("stderr"), do: true
  def start_event?("evidence"), do: true
  def start_event?(_event), do: false
end
