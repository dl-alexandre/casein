defmodule DevIDE.Fleet.ExecutionProjection do
  @moduledoc """
  Derived projection of an execution attempt.

  **Not authoritative.**  The assignment event stream and protocol
  messages remain the durable truth.  This struct is a disposable
  cache built by reducing events through `ExecutionProjectionStore`.

  ## Lifecycle

      pending -> started -> completed
                          -> failed
                          -> abandoned
                          -> expired

  ## Workspace binding

  An execution references a workspace (and optionally a git worktree)
  that was validated at start time, not created by the execution.
  """

  @type state :: :pending | :started | :completed | :failed | :abandoned | :expired

  @type t :: %__MODULE__{
          id: String.t(),
          assignment_id: String.t(),
          runner_id: String.t(),
          lease_id: String.t(),
          state: state(),
          workspace_id: String.t() | nil,
          worktree_path: String.t() | nil,
          git_sha: String.t() | nil,
          tmux_session: String.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failure_reason: String.t() | nil,
          evidence: map()
        }

  @enforce_keys [:id, :assignment_id, :runner_id, :lease_id]
  defstruct [
    :id,
    :assignment_id,
    :runner_id,
    :lease_id,
    :workspace_id,
    :worktree_path,
    :git_sha,
    :tmux_session,
    :started_at,
    :completed_at,
    :failure_reason,
    state: :pending,
    evidence: %{}
  ]
end
