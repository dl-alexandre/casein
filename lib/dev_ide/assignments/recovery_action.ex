defmodule DevIDE.Assignments.RecoveryAction do
  @moduledoc """
  A proposed recovery action for an assignment.

  Recovery actions are **read-first proposals** that an operator can inspect
  before applying.  Every action has a dry-run result that shows what would
  happen without mutating any state.

  ## Risk levels

    * `:safe` — no mutation of the assignment stream (e.g. rebuild projection)
    * `:moderate` — mutates the assignment stream through standard events
    * `:high` — creates a new assignment or alters external state

  ## Kinds

    * `:rebuild_projection` — replay events and overwrite projection cache
    * `:repair_projection` — same as rebuild, exposed under different name
    * `:expire_lease` — emit `:expired` event for a stale claimed/running assignment
    * `:retry_assignment` — create a new assignment with the same workspace/run context
    * `:requeue_assignment` — create a new queued copy after a terminal lease expiry
    * `:clone_assignment` — create a new assignment from an abandoned one
    * `:clone_requeue` — legacy alias for `:clone_assignment`
  """

  @type risk_level :: :safe | :moderate | :high

  @type kind ::
          :rebuild_projection
          | :repair_projection
          | :expire_lease
          | :retry_assignment
          | :requeue_assignment
          | :clone_assignment
          | :clone_requeue

  @type t :: %__MODULE__{
          id: String.t(),
          assignment_id: String.t(),
          kind: kind(),
          reason: String.t(),
          risk_level: risk_level(),
          proposed_by: String.t() | nil,
          proposed_at: DateTime.t(),
          dry_run_result: map() | nil,
          applied_at: DateTime.t() | nil,
          applied: boolean()
        }

  @enforce_keys [:id, :assignment_id, :kind, :reason, :risk_level, :proposed_at]
  defstruct [
    :id,
    :assignment_id,
    :kind,
    :reason,
    :risk_level,
    :proposed_by,
    :proposed_at,
    :dry_run_result,
    :applied_at,
    applied: false
  ]

  @doc "Create a new recovery action proposal."
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end
end
