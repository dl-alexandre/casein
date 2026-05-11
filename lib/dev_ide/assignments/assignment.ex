defmodule DevIDE.Assignments.Assignment do
  @moduledoc """
  Domain struct for a durable orchestrated assignment.

  This is the orchestration-layer view of a unit of work, distinct from
  the wire-protocol `DevIDE.Runners.Assignment` which is runner-facing.
  The orchestration struct carries a `run_id` that links it to the
  canonical run ledger (`DevIDE.Runs.Ledger`).
  """

  @type state :: String.t()

  @type t :: %__MODULE__{
          id: String.t(),
          workspace_id: String.t(),
          run_id: String.t() | nil,
          lease_owner: String.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          state: state(),
          claimed_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failure_reason: String.t() | nil,
          metadata: map(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :workspace_id]
  defstruct [
    :id,
    :workspace_id,
    :run_id,
    :lease_owner,
    :lease_expires_at,
    :state,
    :claimed_at,
    :completed_at,
    :failure_reason,
    :inserted_at,
    :updated_at,
    metadata: %{}
  ]
end
