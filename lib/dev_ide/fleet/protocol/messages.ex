defmodule DevIDE.Fleet.Protocol.Messages do
  @moduledoc """
  Typed protocol messages for the controller ↔ runner boundary.

  ## Controller → Runner (offers / instructions)

    * `AssignmentOffered` — controller offers work to a runner
    * `AssignmentRevoked` — controller cancels an offered/accepted assignment

  ## Runner → Controller (responses / state transitions)

    * `AssignmentAccepted` — runner accepts the offered work
    * `AssignmentRejected` — runner declines the offered work
    * `ExecutionStarted` — runner confirms execution has begun
    * `ExecutionCompleted` — runner confirms successful completion
    * `ExecutionFailed` — runner confirms failure

  ## Runner → Controller (observational — never mutate orchestration state)

    * `OutputChunk` — stdout/stderr stream fragment
    * `ArtifactChunk` — artifact upload fragment
    * `Telemetry` — metrics, resource usage

  ## Bidirectional (lifecycle / health)

    * `Heartbeat` — liveness ping
    * `LeaseRenewed` — lease extension acknowledgment

  ## Rules

    * State transitions only via `ExecutionStarted`, `ExecutionCompleted`, `ExecutionFailed`
    * Observational messages (`OutputChunk`, `ArtifactChunk`, `Telemetry`) never change state
    * Every message must be wrapped in `Protocol.Envelope` before transport
  """

  defmodule AssignmentOffered do
    @moduledoc "Controller offers an assignment to a runner."
    defstruct [:assignment_id, :safe_action_id, :workspace_id, :worktree_path, :lease_duration_ms]
  end

  defmodule AssignmentAccepted do
    @moduledoc "Runner accepts the offered assignment."
    defstruct [:assignment_id]
  end

  defmodule AssignmentRejected do
    @moduledoc "Runner declines the offered assignment."
    defstruct [:assignment_id, :reason]
  end

  defmodule AssignmentRevoked do
    @moduledoc "Controller cancels an offered assignment before execution starts."
    defstruct [:assignment_id, :reason]
  end

  defmodule ExecutionStarted do
    @moduledoc "Runner confirms execution has begun. State transition: pending -> started."
    defstruct [:assignment_id, :execution_id, :started_at]
  end

  defmodule ExecutionCompleted do
    @moduledoc "Runner confirms successful completion. State transition: started -> completed."
    defstruct [:assignment_id, :execution_id, :completed_at, :evidence]
  end

  defmodule ExecutionFailed do
    @moduledoc "Runner confirms failure. State transition: started -> failed."
    defstruct [:assignment_id, :execution_id, :failed_at, :reason, :evidence]
  end

  defmodule ExecutionAbandoned do
    @moduledoc "Runner or controller marks execution as abandoned."
    defstruct [:assignment_id, :execution_id, :reason]
  end

  defmodule OutputChunk do
    @moduledoc """
    Observational: stdout/stderr stream fragment. Never mutates state.

    `seq` provides ordering and loss detection for remote resilience (Track B).
    Runners must emit monotonically increasing sequence numbers per (execution, stream).
    """
    defstruct [:assignment_id, :execution_id, :stream, :chunk, :seq, :timestamp]
  end

  defmodule ArtifactChunk do
    @moduledoc "Observational: artifact upload fragment. Never mutates state."
    defstruct [:assignment_id, :execution_id, :artifact_id, :chunk, :position, :timestamp]
  end

  defmodule Telemetry do
    @moduledoc "Observational: resource usage metrics. Never mutates state."
    defstruct [:runner_id, :cpu_percent, :memory_mb, :timestamp]
  end

  defmodule Heartbeat do
    @moduledoc "Liveness ping from runner to controller."
    defstruct [:runner_id, :active_assignment_id]
  end

  defmodule LeaseRenewed do
    @moduledoc "Acknowledgment that lease has been extended."
    defstruct [:lease_id, :expires_at]
  end

  ## Classification helpers

  @doc "Is this a state-transition message?"
  @spec state_transition?(struct()) :: boolean()
  def state_transition?(%ExecutionStarted{}), do: true
  def state_transition?(%ExecutionCompleted{}), do: true
  def state_transition?(%ExecutionFailed{}), do: true
  def state_transition?(%ExecutionAbandoned{}), do: true
  def state_transition?(_), do: false

  @doc "Is this an observational message (never mutates state)?"
  @spec observational?(struct()) :: boolean()
  def observational?(%OutputChunk{}), do: true
  def observational?(%ArtifactChunk{}), do: true
  def observational?(%Telemetry{}), do: true
  def observational?(_), do: false

  @doc "Is this a lifecycle/health message?"
  @spec lifecycle?(struct()) :: boolean()
  def lifecycle?(%Heartbeat{}), do: true
  def lifecycle?(%LeaseRenewed{}), do: true
  def lifecycle?(_), do: false

  @doc "Return the assignment_id from a message, or nil."
  @spec assignment_id(struct()) :: String.t() | nil
  def assignment_id(%{assignment_id: id}) when is_binary(id), do: id
  def assignment_id(_), do: nil
end
