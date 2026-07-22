defmodule DevIDE.Previews.Deps.PaneSink do
  @moduledoc """
  Preview-owned seam for generic feature-pane lifecycle broadcasts.

  Inverts the single `DevIDE.Panes.Events.broadcast/1` outbound edge.
  """

  @type event :: map()

  @callback broadcast(event()) :: :ok
end
