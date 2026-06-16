defmodule DevIDE.Fleet do
  @moduledoc """
  Fleet topology API — runner registry, lease tracking, and heartbeat.

  This module sits above the JX runner protocol (`DevIDE.Runners`) and
  the orchestration event stream (`DevIDE.Assignments`).  It tracks
  *which physical runners exist*, *what they can do*, and *what they
  are currently executing*.

  All fleet state is ephemeral.  Runners re-register after reconnect;
  leases re-acquire after restart.  The durable truth remains:

    * assignment events (`DevIDE.Assignments.EventStore`)
    * runner assignments (`DevIDE.Runners` protocol)

  ## Lifecycle

    1. Runner registers with capabilities
    2. Runner heartbeats periodically
    3. Fleet acquires lease → runner becomes :busy
    4. Runner releases or lease expires → runner becomes :idle
    5. Missing heartbeats → runner marked :offline → leases expired

  ## Placement primitives (M40 — no scheduling yet)

    * `list_idle_runners/0` — candidates for work
    * `runners_with_capability/1` — capability filter
    * `runner_for_assignment/1` — reverse lookup
  """

  alias DevIDE.Assignments

  alias DevIDE.Fleet.{
    AssignmentRequirements,
    Attach,
    DelegateFlow,
    Dossier,
    ExecutionProjection,
    ExecutionProjectionStore,
    ExecutionStatus,
    ExecutionTimeline,
    Lease,
    LongPollTransport,
    LocalExecutor,
    OperatorNotifications,
    OperatorWorkflow,
    OutputStream,
    PlacementPass,
    Queue,
    Registry,
    Runner,
    RunnerDiagnostics,
    RunnerDirectory,
    Scheduler,
    Takeover
  }

  alias DevIDE.Runners.SafeAction
  alias DevIDE.Runs.Ledger

  ## Runner registration

  @spec register(map()) :: {:ok, Runner.t()} | {:error, term()}
  def register(attrs) when is_map(attrs) do
    attrs =
      attrs
      |> Map.put_new(:id, Ecto.UUID.generate())
      |> Map.put_new(:capabilities, [])
      |> Map.put_new(:metadata, %{})

    runner = %Runner{
      id: Map.fetch!(attrs, :id),
      hostname: Map.fetch!(attrs, :hostname),
      capabilities: Map.get(attrs, :capabilities),
      metadata: Map.get(attrs, :metadata)
    }

    with {:ok, identity} <- RunnerDirectory.ensure_registered(attrs),
         {:ok, runner} <- Registry.register(runner) do
      runner = apply_identity_state(runner, identity)

      if runner.state == :online do
        {:ok, runner}
      else
        Registry.set_runner_state(runner.id, runner.state)
      end
    end
  end

  @spec heartbeat(String.t()) :: {:ok, Runner.t()} | :error | {:error, :runner_revoked}
  def heartbeat(runner_id) do
    with :ok <- runner_not_revoked(runner_id) do
      Registry.heartbeat(runner_id)
    end
  end

  @spec unregister(String.t()) :: :ok
  def unregister(runner_id), do: Registry.unregister(runner_id)

  @spec runner_identity(String.t()) :: {:ok, RunnerDirectory.identity()} | :error
  def runner_identity(runner_id), do: RunnerDirectory.get(runner_id)

  @spec runner_identities(keyword()) :: [RunnerDirectory.identity()]
  def runner_identities(opts \\ []), do: RunnerDirectory.list(opts)

  @spec set_runner_trust_state(String.t(), RunnerDirectory.trust_state(), keyword()) ::
          {:ok, RunnerDirectory.identity()} | :error
  def set_runner_trust_state(runner_id, trust_state, opts \\ []) do
    with {:ok, identity} <- RunnerDirectory.set_trust_state(runner_id, trust_state, opts) do
      _ =
        case trust_state do
          :draining -> Registry.set_runner_state(runner_id, :draining)
          :maintenance -> Registry.set_runner_state(runner_id, :maintenance)
          :revoked -> Registry.set_runner_state(runner_id, :offline)
          :authorized -> Registry.set_runner_state(runner_id, :online)
        end

      {:ok, identity}
    end
  end

  @spec drain_runner(String.t(), keyword()) :: {:ok, RunnerDirectory.identity()} | :error
  def drain_runner(runner_id, opts \\ []) do
    set_runner_trust_state(runner_id, :draining, opts)
  end

  @spec shutdown_runner(String.t(), keyword()) :: {:ok, Runner.t()} | :error
  def shutdown_runner(runner_id, opts \\ []) do
    _ = drain_runner(runner_id, opts)
    :ok = mark_offline([runner_id])
    get_runner(runner_id)
  end

  ## Queries

  @spec list_runners() :: [Runner.t()]
  def list_runners, do: Registry.list_runners()

  @spec get_runner(String.t()) :: {:ok, Runner.t()} | :error
  def get_runner(runner_id), do: Registry.get_runner(runner_id)

  @spec runners_by_state(atom()) :: [Runner.t()]
  def runners_by_state(state), do: Registry.runners_by_state(state)

  @spec idle_runners() :: [Runner.t()]
  def idle_runners, do: runners_by_state(:idle)

  @spec online_runners() :: [Runner.t()]
  def online_runners do
    list_runners()
    |> Enum.filter(&(&1.state in [:online, :idle, :busy]))
  end

  @spec runners_with_capability(String.t()) :: [Runner.t()]
  def runners_with_capability(capability),
    do: Registry.runners_with_capability(capability)

  ## Lease operations

  @spec acquire_lease(String.t(), String.t(), keyword()) ::
          {:ok, Lease.t()} | {:error, :already_leased | :runner_not_found | :runner_busy}
  def acquire_lease(runner_id, assignment_id, opts \\ []) do
    Registry.acquire_lease(runner_id, assignment_id, opts)
  end

  @spec release_lease(String.t()) :: :ok | :error
  def release_lease(assignment_id), do: Registry.release_lease(assignment_id)

  @spec revoke_lease(String.t()) :: :ok | :error
  def revoke_lease(assignment_id), do: Registry.revoke_lease(assignment_id)

  @spec get_lease(String.t()) :: {:ok, Lease.t()} | :error
  def get_lease(assignment_id), do: Registry.get_lease(assignment_id)

  @spec list_leases() :: [Lease.t()]
  def list_leases, do: Registry.list_leases()

  @spec active_leases() :: [Lease.t()]
  def active_leases, do: Registry.active_leases()

  @spec renew_lease(String.t(), String.t(), DateTime.t()) :: {:ok, Lease.t()} | {:error, term()}
  def renew_lease(lease_id, runner_id, %DateTime{} = expires_at),
    do: Registry.renew_lease(lease_id, runner_id, expires_at)

  ## Topology

  @spec assignments_for_runner(String.t()) :: [String.t()]
  def assignments_for_runner(runner_id),
    do: Registry.assignments_for_runner(runner_id)

  @spec runner_for_assignment(String.t()) :: {:ok, String.t()} | :error
  def runner_for_assignment(assignment_id),
    do: Registry.runner_for_assignment(assignment_id)

  ## Health

  @spec detect_stale(non_neg_integer()) :: [Runner.t()]
  def detect_stale(threshold_ms) do
    Registry.detect_stale(threshold_ms)
  end

  @spec expire_leases(DateTime.t()) :: [Lease.t()]
  def expire_leases(now) do
    Registry.expire_leases(now)
  end

  @spec mark_offline([String.t()]) :: :ok
  def mark_offline(runner_ids), do: Registry.mark_offline(runner_ids)

  @spec clear() :: :ok
  def clear, do: Registry.clear()

  ## Local execution loop

  @doc """
  Create, place, and execute one allowlisted workspace command locally.

  This is the first real delegated local loop:

    1. create an orchestration assignment
    2. enqueue placement requirements from the safe-action registry
    3. run a placement pass to acquire a fleet lease
    4. execute through `LocalExecutor`, which reports through the protocol

  The caller supplies only a command id from `DevIDE.Commands.allowlist/0`.
  Raw argv is never accepted here.
  """
  @spec run_safe_command(String.t(), String.t(), keyword()) ::
          {:ok, LocalExecutor.result()} | {:error, term()}
  def run_safe_command(workspace_id, command_id, opts \\ [])

  def run_safe_command(workspace_id, command_id, opts)
      when is_binary(workspace_id) and is_binary(command_id) and is_list(opts) do
    with {:ok, %SafeAction{} = action} <- fetch_command_action(command_id),
         {:ok, assignment} <- create_execution_assignment(workspace_id, action, opts),
         :ok <- enqueue_for_placement(assignment.id, action, opts),
         :ok <- PlacementPass.trigger(),
         {:ok, _lease} <- placed_lease(assignment.id) do
      LocalExecutor.execute_assignment(assignment.id, opts)
    end
  end

  def run_safe_command(_workspace_id, _command_id, _opts), do: {:error, :invalid_attrs}

  @doc """
  Prepare an operator takeover package for an active tmux-backed execution.

  This is read-first: it returns attach instructions and evidence without
  changing assignment state.
  """
  @spec prepare_takeover(String.t(), keyword()) :: {:ok, Takeover.t()} | {:error, term()}
  def prepare_takeover(assignment_id, opts \\ []), do: Takeover.prepare(assignment_id, opts)

  @doc """
  Send operator keystrokes into an active takeover session without mutating
  orchestration state.
  """
  @spec takeover_send_keys(String.t(), String.t(), keyword()) ::
          {:ok, Takeover.intervention()} | {:error, term()}
  def takeover_send_keys(assignment_id, keys, opts \\ []),
    do: Takeover.send_keys(assignment_id, keys, opts)

  @doc "Build a read-only operational dossier for a workspace."
  @spec dossier(String.t(), keyword()) :: {:ok, Dossier.t()} | {:error, term()}
  def dossier(workspace_id, opts \\ []), do: Dossier.workspace(workspace_id, opts)

  @doc "List completed or failed delegated executions that need operator review."
  @spec review_queue(String.t(), keyword()) ::
          {:ok, [OperatorWorkflow.review_item()]} | {:error, term()}
  def review_queue(workspace_id, opts \\ []),
    do: OperatorWorkflow.review_queue(workspace_id, opts)

  @doc "Request approval for a risky operator action."
  @spec request_approval(atom() | String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def request_approval(action, target, opts \\ []),
    do: DevIDE.Fleet.Approvals.request(action, target, opts)

  @doc "Grant a previously requested operator approval."
  @spec grant_approval(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def grant_approval(approval_id, opts \\ []),
    do: DevIDE.Fleet.Approvals.grant(approval_id, opts)

  @doc "Deny a previously requested operator approval."
  @spec deny_approval(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def deny_approval(approval_id, opts \\ []),
    do: DevIDE.Fleet.Approvals.deny(approval_id, opts)

  @doc "Safe reusable operator runbook actions."
  @spec runbook_actions() :: [map()]
  def runbook_actions, do: OperatorWorkflow.runbook_actions()

  @doc "Run one reusable operator runbook action."
  @spec runbook_action(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runbook_action(action_id, workspace_id, opts \\ []),
    do: OperatorWorkflow.runbook_action(action_id, workspace_id, opts)

  @doc "Apply a recovery action after an explicit approval gate."
  @spec apply_approved_recovery(
          DevIDE.Assignments.RecoveryAction.t(),
          String.t() | nil,
          String.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def apply_approved_recovery(action, approval_id, operator_id, opts \\ []),
    do: OperatorWorkflow.apply_approved_recovery(action, approval_id, operator_id, opts)

  @doc "Best-effort operator notifications emitted after committed runtime events."
  @spec operator_notifications(keyword()) :: [OperatorNotifications.t()]
  def operator_notifications(opts \\ []), do: OperatorNotifications.list(opts)

  @doc "Read-only scheduler plan for queued work and runner pools."
  @spec scheduler_plan(keyword()) :: map()
  def scheduler_plan(opts \\ []), do: Scheduler.plan(opts)

  @doc "Build an attach/reconnect packet for an execution."
  @spec attach_packet(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def attach_packet(execution_id, opts \\ []), do: Attach.packet(execution_id, opts)

  @doc "Replay one execution timeline."
  @spec execution_timeline(String.t()) :: {:ok, map()} | {:error, term()}
  def execution_timeline(execution_id), do: ExecutionTimeline.timeline(execution_id)

  ## Execution projection / output — public read API
  #
  # Consumers outside Fleet (e.g. DevIDE.Terminals' session registry and remote
  # output streamer) read execution state through these functions instead of
  # reaching into the ExecutionProjectionStore / OutputStream internals (audit
  # #8 coupling fix). The ExecutionProjection struct and Notification messages
  # remain the shared data contract.

  @doc "All current execution projections."
  @spec list_execution_projections() :: [ExecutionProjection.t()]
  def list_execution_projections, do: ExecutionProjectionStore.list()

  @doc "Fetch one execution projection by execution id."
  @spec get_execution_projection(String.t()) :: {:ok, ExecutionProjection.t()} | :error
  def get_execution_projection(execution_id), do: ExecutionProjectionStore.get(execution_id)

  @doc "Most recent buffered output chunks for an execution (replay tail)."
  @spec execution_output_tail(String.t(), non_neg_integer()) :: [map()]
  def execution_output_tail(execution_id, limit),
    do: OutputStream.last_chunks(execution_id, limit)

  @doc "True when an execution state is terminal (succeeded/failed/abandoned/expired)."
  @spec execution_terminal?(atom()) :: boolean()
  def execution_terminal?(state), do: ExecutionStatus.terminal?(state)

  @doc "Build read-only diagnostics for one runner."
  @spec runner_diagnostics(String.t()) :: {:ok, map()} | {:error, term()}
  def runner_diagnostics(runner_id), do: RunnerDiagnostics.get(runner_id)

  @doc "Run an operator-created approved command sequence as delegated work."
  @spec delegate_task(String.t(), [String.t()], keyword()) ::
          {:ok, DelegateFlow.result()} | {:error, term()}
  def delegate_task(workspace_id, command_ids, opts \\ []),
    do: DelegateFlow.run(workspace_id, command_ids, opts)

  @doc "Long-poll for the next transport offer for a registered runner."
  @spec poll_transport_offer(String.t(), keyword()) ::
          {:ok, LongPollTransport.offer()} | :none | {:error, term()}
  def poll_transport_offer(runner_id, opts \\ []) do
    with :ok <- runner_not_revoked(runner_id) do
      LongPollTransport.poll_offer(runner_id, opts)
    end
  end

  ## Fleet snapshot

  @spec snapshot() :: map()
  def snapshot do
    runners = list_runners()
    leases = active_leases()

    %{
      total_runners: length(runners),
      online: Enum.count(runners, &(&1.state in [:online, :idle, :busy])),
      idle: Enum.count(runners, &(&1.state == :idle)),
      busy: Enum.count(runners, &(&1.state == :busy)),
      offline: Enum.count(runners, &(&1.state in [:offline, :stale])),
      active_leases: length(leases),
      queued_assignments: Queue.count(),
      capabilities:
        runners
        |> Enum.flat_map(& &1.capabilities)
        |> Enum.frequencies()
    }
  end

  @spec scheduling_snapshot() :: map()
  def scheduling_snapshot do
    active_leases = active_leases()

    %{
      runners: list_runners(),
      active_leases: active_leases,
      active_leases_by_runner: Enum.group_by(active_leases, & &1.runner_id),
      active_concurrency_groups: active_concurrency_groups(active_leases),
      queue: Queue.list()
    }
  end

  defp fetch_command_action(command_id) do
    case SafeAction.fetch_command(command_id) do
      {:ok, action} -> {:ok, action}
      :error -> {:error, :safe_action_not_allowed}
    end
  end

  defp create_execution_assignment(workspace_id, %SafeAction{} = action, opts) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> normalize_metadata()
      |> Map.put(:protocol, "devide.fleet.local.v1")
      |> Map.put(:safe_action_id, action.id)
      |> Map.put(:safe_action_version, action.version)
      |> Map.put(:command_id, action.command_id)

    Assignments.create(%{
      workspace_id: workspace_id,
      run_id: Keyword.get(opts, :run_id) || Ledger.new_run_id(),
      actor_id: Keyword.get(opts, :actor_id),
      metadata: metadata
    })
  end

  defp enqueue_for_placement(assignment_id, %SafeAction{} = action, opts) do
    requirements =
      AssignmentRequirements.new(
        capabilities: action.requires,
        priority: Keyword.get(opts, :priority, :normal),
        isolation: Keyword.get(opts, :isolation, :shared),
        max_runtime_ms: Keyword.get(opts, :lease_ms)
      )

    Queue.enqueue(assignment_id, requirements)
  end

  defp placed_lease(assignment_id) do
    case get_lease(assignment_id) do
      {:ok, lease} -> {:ok, lease}
      :error -> {:error, :no_eligible_runner}
    end
  end

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp apply_identity_state(%Runner{} = runner, %{trust_state: :draining}),
    do: %{runner | state: :draining}

  defp apply_identity_state(%Runner{} = runner, %{trust_state: :maintenance}),
    do: %{runner | state: :maintenance}

  defp apply_identity_state(%Runner{} = runner, %{trust_state: :revoked}),
    do: %{runner | state: :offline}

  defp apply_identity_state(%Runner{} = runner, _identity), do: runner

  defp runner_not_revoked(runner_id) do
    case RunnerDirectory.get(runner_id) do
      {:ok, %{trust_state: :revoked}} -> {:error, :runner_revoked}
      _ -> :ok
    end
  end

  defp active_concurrency_groups(active_leases) do
    active_leases
    |> Enum.reduce(%{}, fn lease, acc ->
      case Assignments.get(lease.assignment_id) do
        {:ok, assignment} ->
          case metadata_value(assignment.metadata || %{}, "concurrency_group") do
            group when is_binary(group) and group != "" -> Map.update(acc, group, 1, &(&1 + 1))
            _ -> acc
          end

        :error ->
          acc
      end
    end)
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, existing_atom(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end
end
