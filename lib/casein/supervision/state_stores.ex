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
      Casein.Terminals.NextPrompt.Server,
      # Joins a claimed GitHub issue to the pane working it. Deliberately not in
      # AgentState: bindings must not expire the way state reports do.
      Casein.Terminals.IssueBinding,
      # Durable work handles outlive pane respawn; prune only clears the pane
      # pointer, never the handle id (see #858).
      Casein.Terminals.WorkHandles,
      # Lifts AgentState transitions into Runs.Ledger. Owns open-run identity
      # per pane; AgentState stays Ledger-free (see docs/design/agent-work-as-a-run.md).
      Casein.Runs.AgentLifecycle,
      Casein.Terminals.ClipboardHistory,
      # Suppresses "session vanished" alarms for teardowns Casein performed
      # itself; a leaf so the killer and the reconciler need not reference
      # each other (OneBackend-v3#20076).
      Casein.Terminals.ExpectedRemovals,
      Casein.Audit.MemoryAdapter,
      Casein.Agents.AgentEvents.MemoryAdapter,
      Casein.Codex.Store.MemoryAdapter,
      # Push pipeline — Dispatcher before Registry (Registry calls Dispatcher.watch).
      Casein.Push.Dispatcher,
      Casein.Push.Registry,
      Casein.Workspaces.State.MemoryAdapter,
      Casein.Runtimes.MemoryAdapter
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
