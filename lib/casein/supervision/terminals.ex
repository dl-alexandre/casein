defmodule Casein.Supervision.Terminals do
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
    Casein.Terminals.HostServerAnchor.ensure!()

    children = [
      {Registry, keys: :unique, name: Casein.Terminals.Registry},
      {DynamicSupervisor, name: Casein.Terminals.Supervisor, strategy: :one_for_one},
      {Registry, keys: :unique, name: Casein.Terminals.TopologyRegistry},
      {DynamicSupervisor, name: Casein.Terminals.TopologySupervisor, strategy: :one_for_one},
      # Flag-gated control-mode listener; child_spec returns :ignore when off.
      # Placed after HostServerAnchor.ensure!() above so attach-session never
      # races the server-spawn cwd claim.
      Casein.Terminals.TmuxEvents,
      Casein.Terminals.TmuxJanitor,
      Casein.Terminals.TmuxWindowJanitor,
      # Owns the pending set for undoable window closes. Its ETS table dies
      # with it by design: a crash must un-hide trashed windows, never strand
      # them hidden with no timer left to kill or restore them.
      Casein.Terminals.WindowTrash,
      # Soft-closes finished agent windows *through* WindowTrash above, so the
      # close stays undoable. Starts inert: with no `:done_agent_window_sweep_ms`
      # configured it arms no timer and sweeps nothing.
      Casein.Terminals.DoneAgentWindows,
      Casein.Mobile.TerminalReaper
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
