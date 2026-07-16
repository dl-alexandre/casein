defmodule DevIDE.Supervision.Agents do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: DevIDE.Agents.Registry},
      {DynamicSupervisor, name: DevIDE.Agents.Supervisor, strategy: :one_for_one},
      DevIDE.AgentSessions.GrokACP.Attachments,
      DevIDE.Agents.MCPSessions,
      DevIDE.Agents.Activity
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
