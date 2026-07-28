defmodule Casein.Supervision.StateStores do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Casein.Labels.Server,
      Casein.Terminals.AgentState.Server,
      Casein.Terminals.ClipboardHistory,
      Casein.Audit.MemoryAdapter,
      Casein.Agents.AgentEvents.MemoryAdapter,
      Casein.Codex.Store.MemoryAdapter,
      # Push pipeline — Dispatcher before Registry (Registry calls Dispatcher.watch).
      Casein.Push.Dispatcher,
      Casein.Push.Registry,
      Casein.Workspaces.State.MemoryAdapter,
      Casein.Workspaces.AgentWriteUnlockExpirer,
      Casein.Runtimes.MemoryAdapter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
