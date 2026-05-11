defmodule DevIDE.Search.Result do
  @moduledoc "A single ripgrep match, normalised for the UI."

  @type t :: %__MODULE__{
          path: String.t(),
          line: pos_integer(),
          column: pos_integer() | nil,
          preview: String.t()
        }

  defstruct [:path, :line, :column, :preview]
end
