defmodule DevIDE.Runtimes.StateMachine do
  @moduledoc """
  Runtime lifecycle state machine and event reducer.

  This state machine controls environment placement only. It does not authorize
  commands, add safe-action kinds, or let runners create work.
  """

  alias DevIDE.Runtimes.LifecycleEvent

  @statuses ~w(requested provisioned bound active idle expired failed cleaned)
  @terminal ~w(cleaned)

  def statuses, do: @statuses
  def terminal_statuses, do: @terminal
  def terminal?(status), do: status in @terminal

  def transition(nil, :request), do: {:ok, "requested"}
  def transition("requested", :provision), do: {:ok, "provisioned"}
  def transition("requested", :fail), do: {:ok, "failed"}
  def transition("requested", :expire), do: {:ok, "expired"}
  def transition("provisioned", :bind), do: {:ok, "bound"}
  def transition("provisioned", :activate), do: {:ok, "active"}
  def transition("provisioned", :idle), do: {:ok, "idle"}
  def transition("provisioned", :expire), do: {:ok, "expired"}
  def transition("provisioned", :fail), do: {:ok, "failed"}
  def transition("bound", :bind), do: {:ok, "bound"}
  def transition("bound", :activate), do: {:ok, "active"}
  def transition("bound", :idle), do: {:ok, "idle"}
  def transition("bound", :expire), do: {:ok, "expired"}
  def transition("bound", :fail), do: {:ok, "failed"}
  def transition("active", :activate), do: {:ok, "active"}
  def transition("active", :idle), do: {:ok, "idle"}
  def transition("active", :expire), do: {:ok, "expired"}
  def transition("active", :fail), do: {:ok, "failed"}
  def transition("idle", :bind), do: {:ok, "bound"}
  def transition("idle", :activate), do: {:ok, "active"}
  def transition("idle", :idle), do: {:ok, "idle"}
  def transition("idle", :expire), do: {:ok, "expired"}
  def transition("idle", :fail), do: {:ok, "failed"}
  def transition("expired", :cleanup), do: {:ok, "cleaned"}
  def transition("failed", :cleanup), do: {:ok, "cleaned"}
  def transition("idle", :cleanup), do: {:ok, "cleaned"}
  def transition("provisioned", :cleanup), do: {:ok, "cleaned"}
  def transition(status, _event) when status in @terminal, do: {:error, :runtime_terminal}
  def transition(_status, _event), do: {:error, :invalid_runtime_transition}

  def event_transition("runtime_requested"), do: :request
  def event_transition("runtime_provisioned"), do: :provision
  def event_transition("runtime_bound"), do: :bind
  def event_transition("runtime_active"), do: :activate
  def event_transition("runtime_idle"), do: :idle
  def event_transition("runtime_expired"), do: :expire
  def event_transition("runtime_failed"), do: :fail
  def event_transition("runtime_cleaned"), do: :cleanup
  def event_transition("runtime_heartbeat"), do: :heartbeat
  def event_transition(_), do: :unknown

  @doc "Reduce a lifecycle event stream into the projected status."
  def reduce(events) when is_list(events) do
    Enum.reduce_while(events, nil, fn %LifecycleEvent{} = event, status ->
      transition_event(status, event.event)
      |> case do
        {:ok, next} -> {:cont, next}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      status -> {:ok, status}
    end
  end

  def transition_event(status, event) when is_binary(event) do
    case event_transition(event) do
      :heartbeat -> {:ok, status}
      :unknown -> {:error, :unknown_runtime_event}
      transition -> transition(status, transition)
    end
  end
end
