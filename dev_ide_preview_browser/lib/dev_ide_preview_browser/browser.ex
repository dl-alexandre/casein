defmodule DevIDEPreviewBrowser.Browser do
  @moduledoc """
  Opaque handle for a browser instance owned by a session.
  """

  @enforce_keys [:id, :session]
  defstruct [:id, :session]

  @type id :: String.t()

  @opaque t :: %__MODULE__{
            id: id(),
            session: GenServer.server()
          }
end
