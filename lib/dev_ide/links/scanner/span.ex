defmodule DevIDE.Links.Scanner.Span do
  @moduledoc """
  A candidate link span in one terminal row.

  Offsets are zero-based byte offsets into the scanned row. They are not
  terminal cell columns; UI overlays must convert bytes to grid cells before
  positioning.
  """

  @enforce_keys [:col_start, :col_end, :raw]
  defstruct [:col_start, :col_end, :raw]

  @type t :: %__MODULE__{
          col_start: non_neg_integer(),
          col_end: non_neg_integer(),
          raw: String.t()
        }
end
