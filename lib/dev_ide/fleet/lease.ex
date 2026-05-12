defmodule DevIDE.Fleet.Lease do
  @moduledoc """
  A fleet-level lease binding a runner to an assignment.

  Distinct from the runner-protocol lease expiry in `DevIDE.Runners`.
  This is the *fleet topology* view: which runner is executing which
  assignment right now.

  ## States

    * `:active` — runner holds the assignment, heartbeat valid
    * `:expired` — lease timed out without heartbeat renewal
    * `:released` — runner explicitly released the assignment
    * `:revoked` — controller forcibly revoked the lease

  A lease is uniquely identified by `{runner_id, assignment_id}`.
  Only one lease per assignment may be active at a time.
  """

  @type state :: :active | :expired | :released | :revoked

  @type t :: %__MODULE__{
          id: String.t(),
          assignment_id: String.t(),
          runner_id: String.t(),
          acquired_at: DateTime.t(),
          expires_at: DateTime.t(),
          released_at: DateTime.t() | nil,
          state: state()
        }

  @enforce_keys [:id, :assignment_id, :runner_id, :acquired_at, :expires_at]
  defstruct [
    :id,
    :assignment_id,
    :runner_id,
    :acquired_at,
    :expires_at,
    :released_at,
    state: :active
  ]
end
