defmodule Casein.Supervision.Agents do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Casein.Agents.Registry},
      {DynamicSupervisor, name: Casein.Agents.Supervisor, strategy: :one_for_one},
      Casein.AgentSessions.GrokACP.Attachments,
      {Registry, keys: :unique, name: Casein.Codex.Registry},
      Casein.Codex.EventHub,
      Casein.Codex.RuntimeSupervisor,
      Casein.Agents.MCPSessions,
      Casein.Agents.Activity
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
