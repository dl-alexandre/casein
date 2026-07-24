defmodule Casein.Proposals.Proposal do
  @moduledoc "A single discovered proposal artifact (read-only, never applied)."

  @type status :: :parsed | :too_large | :invalid | :unsupported
  @type change :: %{path: String.t(), kind: :add | :delete | :modify | :unknown}

  @type t :: %__MODULE__{
          rel_path: String.t(),
          name: String.t(),
          size: non_neg_integer(),
          mtime: NaiveDateTime.t() | nil,
          parser: :unified_diff | :unsupported,
          status: status(),
          changes: [change()],
          diff: String.t() | nil,
          truncated: boolean(),
          error: String.t() | nil
        }

  defstruct rel_path: "",
            name: "",
            size: 0,
            mtime: nil,
            parser: :unified_diff,
            status: :unsupported,
            changes: [],
            diff: nil,
            truncated: false,
            error: nil
end
