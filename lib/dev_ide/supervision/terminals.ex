defmodule DevIde.Supervision.Terminals do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # Claim the host tmux server from a stable cwd BEFORE the Session
    # DynamicSupervisor (and, transitively, the Endpoint) can lazily spawn it
    # from a disposable worktree. Synchronous + never-raises by design.
    DevIDE.Terminals.HostServerAnchor.ensure!()

    children = [
      {Registry, keys: :unique, name: DevIDE.Terminals.Registry},
      {DynamicSupervisor, name: DevIDE.Terminals.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: DevIDE.Terminals.TopologyRegistry},
      {DynamicSupervisor, name: DevIDE.Terminals.TopologySupervisor, strategy: :one_for_one},
      DevIDE.Terminals.TmuxJanitor,
      DevIDE.Terminals.TmuxWindowJanitor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
