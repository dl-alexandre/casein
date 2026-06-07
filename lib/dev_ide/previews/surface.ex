defmodule DevIDE.Previews.Surface do
  @moduledoc """
  A named preview surface for a workspace — the app URL, Tidewave endpoint,
  API gateway, or a localhost dev server discovered from terminal output.
  """

  @type source :: :manager | :terminal
  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          title: String.t(),
          port: integer() | nil,
          source: source()
        }

  defstruct [:name, :url, :title, :port, :source]
end
