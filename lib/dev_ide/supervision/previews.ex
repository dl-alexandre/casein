defmodule DevIde.Supervision.Previews do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      DevIDE.PreviewActivity,
      DevIDE.PreviewPanes,
      PreviewCtl.Registry,
      {Registry, keys: :duplicate, name: DevIdeWeb.PreviewProxy.WebSocketRegistry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
