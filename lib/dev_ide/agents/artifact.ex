defmodule DevIDE.Agents.Artifact do
  @moduledoc "A read-only file pointer surfaced by Agents detection (e.g. transcripts)."

  @type t :: %__MODULE__{
          rel_path: String.t(),
          name: String.t(),
          size: non_neg_integer(),
          mtime: NaiveDateTime.t() | nil
        }

  defstruct [:rel_path, :name, :size, :mtime]
end
