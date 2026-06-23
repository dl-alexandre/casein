defmodule DevIDE.Previews.Surface do
  @moduledoc """
  A named preview surface for a workspace — the app URL, Tidewave endpoint,
  API gateway, or a localhost dev server discovered from terminal output.
  """

  @type source :: :manager | :terminal | :host | :detected | :runtime
  @type t :: %__MODULE__{
          name: String.t(),
          url: String.t(),
          title: String.t(),
          port: integer() | nil,
          source: source(),
          runtime_id: String.t() | nil,
          surface_key: String.t() | nil,
          tmux_session: String.t() | nil
        }

  defstruct [:name, :url, :title, :port, :source, :runtime_id, :surface_key, :tmux_session]
end
