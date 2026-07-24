defmodule Casein.Previews.Deps.PaneSink do
  @moduledoc """
  Preview-owned seam for generic feature-pane lifecycle broadcasts.

  Inverts the single `Casein.Panes.Events.broadcast/1` outbound edge.
  """

  @type event :: map()

  @callback broadcast(event()) :: :ok
end
