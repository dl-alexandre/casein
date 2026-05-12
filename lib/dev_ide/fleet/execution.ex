defmodule DevIDE.Fleet.Execution do
  @moduledoc """
  A concrete execution attempt by a runner for an assignment.

  ## Vocabulary discipline

    * `Assignment` — orchestration intent (what work should happen)
    * `Execution` — a concrete runner attempt at that work
    * `Run Ledger` — durable artifact/output timeline

  An assignment may have multiple executions (retries). Each execution
  is scoped to a single lease and a single runner.

  ## State machine

      pending -> started -> completed
                          -> failed
                          -> abandoned
                          -> expired

  Observational data (stdout, stderr, artifacts, telemetry) is **never**
  stored on this struct. It flows to the Run Ledger as append-only
  artifacts.
  """

  @type state :: :pending | :started | :completed | :failed | :abandoned | :expired

  @type t :: %__MODULE__{
          id: String.t(),
          assignment_id: String.t(),
          runner_id: String.t(),
          lease_id: String.t(),
          state: state(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          failure_reason: String.t() | nil,
          evidence: map(),
          metadata: map()
        }

  @enforce_keys [:id, :assignment_id, :runner_id, :lease_id]
  defstruct [
    :id,
    :assignment_id,
    :runner_id,
    :lease_id,
    :started_at,
    :completed_at,
    :failure_reason,
    state: :pending,
    evidence: %{},
    metadata: %{}
  ]

  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end
end
