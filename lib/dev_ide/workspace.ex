defmodule DevIDE.Workspace do
  @moduledoc """
  Public workspace value. Source-agnostic.

  Every `DevIDE.WorkspaceSource` returns this struct. Source-specific extras
  (HTTP payloads, ports, slots, domain bases) live under `:metadata` so the
  rest of the system never sees source-shape leakage.
  """

  @type status ::
          :creating | :queued | :starting | :running | :stopped | :deleting | :error | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          user: String.t() | nil,
          branch: String.t() | nil,
          status: status(),
          path: String.t() | nil,
          metadata: map()
        }

  defstruct [
    :id,
    :name,
    :user,
    :branch,
    :path,
    status: :unknown,
    metadata: %{}
  ]
end
