defmodule Casein.Links.Resolver.Ctx do
  @moduledoc """
  Context for resolving explicit link targets.

  `base_dir` is the terminal pane cwd, a document dirname, or nil to resolve
  relative paths from the workspace root.
  """

  @enforce_keys [:workspace]
  defstruct [:workspace, :base_dir, :pane_id, source: :terminal]

  @type source :: :terminal | :doc | :api

  @type t :: %__MODULE__{
          workspace: map(),
          base_dir: String.t() | nil,
          pane_id: String.t() | nil,
          source: source()
        }
end
