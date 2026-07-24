defmodule Casein.Elixir.Symbol do
  @moduledoc "A single Elixir symbol surfaced from a regex pass over a file."

  @type kind ::
          :module | :function | :macro | :guard | :delegate | :test | :describe

  @type visibility :: :public | :private | nil

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t(),
          line: pos_integer(),
          arity: non_neg_integer() | nil,
          visibility: visibility()
        }

  defstruct [:kind, :name, :line, :arity, :visibility]
end
