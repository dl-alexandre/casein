defmodule DevIDE.Palette.Item do
  @moduledoc "A single palette result row."

  @type kind :: :file | :action | :command | :tab
  @type t :: %__MODULE__{
          id: String.t(),
          kind: kind(),
          label: String.t(),
          detail: String.t() | nil,
          score: integer(),
          payload: map()
        }

  @enforce_keys [:id, :kind, :label]
  defstruct [:id, :kind, :label, :detail, score: 0, payload: %{}]
end
