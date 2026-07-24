defmodule Casein.Supervision.Previews do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Casein.PreviewActivity,
      Casein.Previews.ArtifactProtection,
      Casein.PreviewPanes,
      Casein.FilePanes,
      Casein.FilePanes.SuffixIndex,
      Casein.FilePanes.LinkResolver,
      {Registry, keys: :unique, name: Casein.Previews.FileServer.Registry},
      {DynamicSupervisor, name: Casein.Previews.FileServer.Supervisor, strategy: :one_for_one},
      PreviewCtl.Registry,
      {Registry, keys: :duplicate, name: CaseinWeb.PreviewProxy.WebSocketRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
