defmodule Casein.Panes.PreviewDeps do
  @moduledoc """
  Core-side impl of `Casein.Previews.Deps.PaneSink`.

  Thin pure delegation to `Casein.Panes.Events.broadcast/1`.
  """

  @behaviour Casein.Previews.Deps.PaneSink

  alias Casein.Panes.Events

  @impl true
  def broadcast(event), do: Events.broadcast(event)
end
