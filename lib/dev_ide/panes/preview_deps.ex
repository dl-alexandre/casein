defmodule DevIDE.Panes.PreviewDeps do
  @moduledoc """
  Core-side impl of `DevIDE.Previews.Deps.PaneSink`.

  Thin pure delegation to `DevIDE.Panes.Events.broadcast/1`.
  """

  @behaviour DevIDE.Previews.Deps.PaneSink

  alias DevIDE.Panes.Events

  @impl true
  def broadcast(event), do: Events.broadcast(event)
end
