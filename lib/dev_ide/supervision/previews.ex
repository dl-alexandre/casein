defmodule DevIDE.Supervision.Previews do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      DevIDE.PreviewActivity,
      DevIDE.Previews.ArtifactProtection,
      DevIDE.PreviewPanes,
      DevIDE.FilePanes,
      DevIDE.FilePanes.SuffixIndex,
      DevIDE.FilePanes.LinkResolver,
      {Registry, keys: :unique, name: DevIDE.Previews.FileServer.Registry},
      {DynamicSupervisor, name: DevIDE.Previews.FileServer.Supervisor, strategy: :one_for_one},
      PreviewCtl.Registry,
      {Registry, keys: :duplicate, name: DevIdeWeb.PreviewProxy.WebSocketRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
