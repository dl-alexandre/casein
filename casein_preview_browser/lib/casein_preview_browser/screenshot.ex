defmodule CaseinPreviewBrowser.Screenshot do
  @moduledoc """
  Screenshot bytes and metadata returned by a browser backend.
  """

  @enforce_keys [:mime_type, :bytes]
  defstruct [:mime_type, :bytes, metadata: %{}]

  @type t :: %__MODULE__{
          mime_type: String.t(),
          bytes: binary(),
          metadata: map()
        }
end
