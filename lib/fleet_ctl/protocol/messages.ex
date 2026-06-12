defmodule FleetCtl.Protocol.Messages do
  @moduledoc """
  Typed protocol messages for the controller ↔ runner boundary.

  Classification helpers match on the message module name suffix so they work
  for host-specific struct modules (for example `DevIDE.Fleet.Protocol.Messages.*`)
  as well as the canonical `FleetCtl.Protocol.Messages.*` structs.
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

  @state_transitions ~w(ExecutionStarted ExecutionCompleted ExecutionFailed ExecutionAbandoned)
  @observational ~w(OutputChunk ArtifactChunk Telemetry)
  @lifecycle ~w(Heartbeat LeaseRenewed)

  @doc "Is this a state-transition message?"
  @spec state_transition?(struct()) :: boolean()
  def state_transition?(%_{} = msg), do: module_suffix(msg) in @state_transitions
  def state_transition?(_), do: false

  @doc "Is this an observational message (never mutates state)?"
  @spec observational?(struct()) :: boolean()
  def observational?(%_{} = msg), do: module_suffix(msg) in @observational
  def observational?(_), do: false

  @doc "Is this a lifecycle/health message?"
  @spec lifecycle?(struct()) :: boolean()
  def lifecycle?(%_{} = msg), do: module_suffix(msg) in @lifecycle
  def lifecycle?(_), do: false

  @doc "Return the assignment_id from a message, or nil."
  @spec assignment_id(struct()) :: String.t() | nil
  def assignment_id(%{assignment_id: id}) when is_binary(id), do: id
  def assignment_id(_), do: nil

  defp module_suffix(%_{} = struct) do
    struct.__struct__ |> Module.split() |> List.last()
  end
end
