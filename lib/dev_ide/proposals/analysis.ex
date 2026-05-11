defmodule DevIDE.Proposals.Analysis do
  @moduledoc """
  Result of comparing a proposal against the current workspace working tree.
  """

  @type risk :: :clean | :overlap | :conflict | :invalid

  @type file_overlap :: %{
          path: String.t(),
          kind: :add | :modify | :delete,
          status: :no_workspace_change | :overlap | :conflict,
          hunks: [map()]
        }

  @type t :: %__MODULE__{
          risk: risk(),
          reason: String.t() | nil,
          files: [file_overlap()],
          overlapping_files: [String.t()],
          files_count: non_neg_integer()
        }

  defstruct risk: :invalid,
            reason: nil,
            files: [],
            overlapping_files: [],
            files_count: 0
end
