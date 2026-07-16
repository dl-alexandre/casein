defmodule DevIDE.Supervision.StateStores do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      DevIDE.Labels.Server,
      DevIDE.Terminals.AgentState.Server,
      DevIDE.Audit.MemoryAdapter,
      DevIDE.Agents.AgentEvents.MemoryAdapter,
      # Push pipeline — Dispatcher before Registry (Registry calls Dispatcher.watch).
      DevIDE.Push.Dispatcher,
      DevIDE.Push.Registry,
      DevIDE.Workspaces.State.MemoryAdapter,
      DevIDE.Workspaces.AgentWriteUnlockExpirer,
      DevIDE.Runtimes.MemoryAdapter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
