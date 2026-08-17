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
      # Duplicate: many cockpit LiveViews may watch the same workspace for
      # one-shot inspector surface intents (diff/run). Process-linked presence.
      {Registry, keys: :duplicate, name: Casein.Inspectors.Diff.ViewerRegistry},
      {Registry, keys: :duplicate, name: Casein.Inspectors.Run.ViewerRegistry},
      # Same shape, for browser-control actions (reload/focus/visible mutation).
      # Those are only meaningful with a tab open, and PubSub cannot report that.
      {Registry,
       keys: :duplicate, name: Casein.Agents.PreviewTools.BrowserControl.ViewerRegistry},
      Casein.Codex.EventHub,
      Casein.Codex.SessionTitles,
      Casein.Codex.RuntimeSupervisor,
      Casein.Agents.MCPSessions,
      {Task.Supervisor, name: Casein.Agents.MCPTaskSupervisor},
      Casein.Agents.MCPTasks,
      Casein.Agents.Activity
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
