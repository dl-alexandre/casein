defmodule Casein.Agents.JidoPod.Attempt do
  @moduledoc """
  Durable-in-memory identity and explicit lifecycle for one headless attempt.
  """

  @states [
    :admitted,
    :queued,
    :running,
    :awaiting_human,
    :retrying,
    :completed,
    :failed,
    :cancelled,
    :timed_out,
    :provider_unavailable
  ]

  @terminal [
    :completed,
    :failed,
    :cancelled,
    :timed_out,
    :provider_unavailable
  ]

  @max_public_completed 100
  @max_public_paths 100
  @max_public_changes 100
  @public_git_keys [
    :repository,
    :base_branch,
    :head_branch,
    :head_sha,
    :release_sha,
    :pr_number,
    :pr_url,
    :outcome,
    :merged_sha,
    :merge_actor_ref,
    :post_merge_evidence_ref
  ]

  alias Casein.Agents.JidoWorkcell.Git.Scope
  alias Casein.Agents.JidoWorkcell.{OwnerRef, Receipt}

  @type state ::
          :admitted
          | :queued
          | :running
          | :awaiting_human
          | :retrying
          | :completed
          | :failed
          | :cancelled
          | :timed_out
          | :provider_unavailable

  @type action :: %{
          required(:name) => String.t(),
          optional(:args) => map(),
          optional(:mutation_token) => String.t()
        }

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t() | nil,
          workcell_id: String.t() | nil,
          workcell_assigned?: boolean(),
          source: String.t() | nil,
          worker_id: String.t(),
          runtime_id: String.t(),
          owner_ref: OwnerRef.t(),
          workspace_id: String.t(),
          task_id: String.t() | nil,
          correlation_id: String.t() | nil,
          receipt_id: String.t() | nil,
          request_id: String.t() | nil,
          authorization: map() | nil,
          evidence_ref: String.t() | nil,
          decision_id: String.t() | nil,
          origin: atom() | String.t() | nil,
          lane: atom() | String.t() | nil,
          worktree_path: String.t() | nil,
          git_scope: Scope.t() | nil,
          lease_id: String.t() | nil,
          base_branch: String.t() | nil,
          head_branch: String.t() | nil,
          repository: String.t() | nil,
          release_sha: String.t() | nil,
          principal: String.t() | nil,
          state: state(),
          reason: term(),
          worker_pid: pid() | nil,
          worker_ref: reference() | nil,
          lease?: boolean(),
          cancel_requested?: boolean(),
          deadline_ms: pos_integer(),
          action_timeout_ms: pos_integer(),
          actions: [action()],
          next_index: non_neg_integer(),
          completed: [map()],
          result: term(),
          error: term(),
          retries: non_neg_integer(),
          max_retries: non_neg_integer(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t(),
          last_progress_at: DateTime.t(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          event_sequence: non_neg_integer(),
          completion_receipt: map() | nil
        }

  @enforce_keys [
    :id,
    :worker_id,
    :runtime_id,
    :owner_ref,
    :workspace_id,
    :state,
    :inserted_at,
    :updated_at,
    :last_progress_at
  ]
  defstruct [
    :id,
    :session_id,
    :workcell_id,
    :workcell_assigned?,
    :source,
    :worker_id,
    :runtime_id,
    :owner_ref,
    :workspace_id,
    :task_id,
    :worktree_path,
    :git_scope,
    :correlation_id,
    :receipt_id,
    :request_id,
    :authorization,
    :evidence_ref,
    :decision_id,
    :origin,
    :lane,
    :lease_id,
    :base_branch,
    :head_branch,
    :repository,
    :release_sha,
    :principal,
    :state,
    :reason,
    :worker_pid,
    :worker_ref,
    :deadline_ms,
    :action_timeout_ms,
    :result,
    :error,
    :started_at,
    :finished_at,
    :completion_receipt,
    lease?: false,
    cancel_requested?: false,
    actions: [],
    next_index: 0,
    completed: [],
    retries: 0,
    max_retries: 1,
    event_sequence: 0,
    inserted_at: nil,
    updated_at: nil,
    last_progress_at: nil
  ]

  @spec states() :: [state()]
  def states, do: @states

  @spec terminal?(state() | t()) :: boolean()
  def terminal?(%__MODULE__{state: state}), do: terminal?(state)
  def terminal?(state) when state in @terminal, do: true
  def terminal?(_), do: false

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs) do
    now = DateTime.utc_now()
    workspace_id = Map.fetch!(attrs, :workspace_id)
    worker_id = "worker-" <> id_suffix()
    runtime_id = "runtime-" <> id_suffix()
    owner_ref = owner_ref(Map.get(attrs, :owner_ref), workspace_id)

    git_scope =
      case Map.get(attrs, :git_scope) do
        %Scope{} = scope ->
          case Scope.with_identity(scope, %{
                 workspace_id: workspace_id,
                 owner_ref: owner_ref,
                 runtime_id: runtime_id,
                 worker_id: worker_id,
                 release_sha: Map.get(attrs, :release_sha)
               }) do
            {:ok, scope} -> scope
            {:error, _reason} -> scope
          end

        other ->
          other
      end

    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      session_id: Map.get(attrs, :session_id),
      workcell_id: Map.get(attrs, :workcell_id),
      workcell_assigned?: Map.get(attrs, :workcell_assigned?, false) == true,
      source: Map.get(attrs, :source),
      worker_id: worker_id,
      runtime_id: runtime_id,
      owner_ref: owner_ref,
      workspace_id: workspace_id,
      task_id: Map.get(attrs, :task_id),
      correlation_id: Map.get(attrs, :correlation_id),
      receipt_id: Map.get(attrs, :receipt_id),
      request_id: Map.get(attrs, :request_id),
      authorization: Map.get(attrs, :authorization),
      evidence_ref: Map.get(attrs, :evidence_ref),
      decision_id: Map.get(attrs, :decision_id),
      origin: Map.get(attrs, :origin),
      lane: Map.get(attrs, :lane),
      lease_id: Map.get(attrs, :lease_id),
      worktree_path: Map.get(attrs, :worktree_path),
      git_scope: git_scope,
      base_branch: Map.get(attrs, :base_branch),
      head_branch: Map.get(attrs, :head_branch),
      repository: Map.get(attrs, :repository),
      release_sha: Map.get(attrs, :release_sha),
      principal: Map.get(attrs, :principal),
      state: :admitted,
      deadline_ms: Map.get(attrs, :deadline_ms, 60_000),
      action_timeout_ms: Map.get(attrs, :action_timeout_ms, 5_000),
      actions: Map.get(attrs, :actions, []),
      max_retries: Map.get(attrs, :max_retries, 1),
      inserted_at: now,
      updated_at: now,
      last_progress_at: now
    }
  end

  @spec transition(t(), state(), keyword()) :: t()
  def transition(%__MODULE__{} = attempt, state, opts \\ []) when state in @states do
    now = Keyword.get(opts, :at, DateTime.utc_now())

    %{
      attempt
      | state: state,
        reason: Keyword.get(opts, :reason, attempt.reason),
        result: Keyword.get(opts, :result, attempt.result),
        error: Keyword.get(opts, :error, attempt.error),
        worker_pid: Keyword.get(opts, :worker_pid, attempt.worker_pid),
        worker_ref: Keyword.get(opts, :worker_ref, attempt.worker_ref),
        lease?: Keyword.get(opts, :lease?, attempt.lease?),
        lease_id: Keyword.get(opts, :lease_id, attempt.lease_id),
        cancel_requested?: Keyword.get(opts, :cancel_requested?, attempt.cancel_requested?),
        next_index: Keyword.get(opts, :next_index, attempt.next_index),
        completed: Keyword.get(opts, :completed, attempt.completed),
        retries: Keyword.get(opts, :retries, attempt.retries),
        completion_receipt:
          Keyword.get(opts, :completion_receipt) ||
            receipt_from(Keyword.get(opts, :result)) || attempt.completion_receipt,
        event_sequence: Keyword.get(opts, :event_sequence, attempt.event_sequence + 1),
        updated_at: now,
        last_progress_at: now,
        started_at: started_at(attempt, state, now),
        finished_at: finished_at(attempt, state, now)
    }
  end

  @spec remaining_actions(t()) :: [action()]
  def remaining_actions(%__MODULE__{actions: actions, next_index: index}) do
    Enum.drop(actions, index)
  end

  @spec public(t()) :: map()
  def public(%__MODULE__{} = attempt) do
    %{
      attempt_id: attempt.id,
      session_id: attempt.session_id,
      workcell_id: attempt.workcell_id,
      workcell_assigned?: attempt.workcell_assigned?,
      source: attempt.source,
      worker_id: attempt.worker_id,
      runtime_id: attempt.runtime_id,
      owner_ref: attempt.owner_ref,
      workspace_id: attempt.workspace_id,
      task_id: attempt.task_id,
      correlation_id: attempt.correlation_id,
      receipt_id: attempt.receipt_id,
      request_id: attempt.request_id,
      evidence_ref: attempt.evidence_ref,
      decision_id: attempt.decision_id,
      origin: attempt.origin,
      lane: attempt.lane,
      worktree_path: attempt.worktree_path,
      base_branch: attempt.base_branch,
      head_branch: attempt.head_branch,
      repository: attempt.repository,
      release_sha: attempt.release_sha,
      lease_id: attempt.lease_id,
      git_scope: public_scope(attempt.git_scope),
      state: attempt.state,
      reason: public_payload(attempt.reason),
      result: public_payload(attempt.result),
      error: public_payload(attempt.error),
      retries: attempt.retries,
      next_index: attempt.next_index,
      completed_count: length(attempt.completed),
      last_progress_at: attempt.last_progress_at,
      inserted_at: attempt.inserted_at,
      updated_at: attempt.updated_at,
      started_at: attempt.started_at,
      finished_at: attempt.finished_at,
      sequence: attempt.event_sequence,
      completion_receipt: public_receipt(attempt.completion_receipt),
      headless: true
    }
    |> Enum.reject(fn {key, value} ->
      is_nil(value) and key in [:session_id, :workcell_id, :task_id, :correlation_id, :lease_id]
    end)
    |> Map.new()
  end

  defp started_at(%{started_at: nil}, :running, now), do: now
  defp started_at(%{started_at: started}, _state, _now), do: started

  defp finished_at(attempt, state, now) do
    if terminal?(state), do: attempt.finished_at || now, else: nil
  end

  defp public_payload(nil), do: nil

  defp public_payload(%{completed: completed}) when is_list(completed) do
    %{
      completed_count: length(completed),
      completed: Enum.take(completed, @max_public_completed) |> Enum.map(&public_completed/1),
      completed_truncated?: length(completed) > @max_public_completed
    }
  end

  defp public_payload(%{} = payload) do
    [
      :status,
      :result,
      :error,
      :retryable,
      :timed_out,
      :cancelled,
      :output_truncated,
      :exit_code,
      :command_id,
      :paths,
      :changed_files,
      :tests,
      :artifacts,
      :schema_version,
      :contract,
      :kind,
      :source,
      :receipt_id,
      :request_id,
      :handoff_id,
      :head_sha,
      :git,
      :occurred_at,
      :redaction,
      :base_branch,
      :head_branch,
      :repository,
      :workspace_id,
      :owner_ref,
      :runtime_id,
      :worker_id,
      :release_sha,
      :idempotency_key,
      :idempotency,
      :files,
      :evidence_ref,
      :decision_id,
      :session_id,
      :workcell_id,
      :task_id,
      :lease_id,
      :correlation_id,
      :changes,
      :reason
    ]
    |> Enum.reduce(%{}, fn key, acc -> put_public_field(acc, key, Map.get(payload, key)) end)
    |> case do
      %{} = summary when map_size(summary) == 0 -> nil
      summary -> summary
    end
  end

  defp public_payload(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: public_scalar(value)

  defp public_payload(_value), do: :present

  defp public_completed(%{} = completed) do
    %{}
    |> put_public_field(:index, Map.get(completed, :index))
    |> put_public_field(:name, Map.get(completed, :name))
    |> put_public_field(:result, Map.get(completed, :result))
  end

  defp public_completed(_completed), do: %{result: :present}

  defp put_public_field(acc, _key, nil), do: acc

  defp put_public_field(acc, key, value) when key in [:result, :error, :reason] do
    case public_payload(value) do
      nil -> acc
      payload -> Map.put(acc, key, payload)
    end
  end

  defp put_public_field(acc, :paths, paths) when is_list(paths) do
    paths =
      paths
      |> Enum.filter(&is_binary/1)
      |> Enum.take(@max_public_paths)
      |> Enum.map(&public_scalar/1)

    if paths == [], do: acc, else: Map.put(acc, :paths, paths)
  end

  defp put_public_field(acc, :changes, changes) when is_list(changes) do
    changes = Enum.take(changes, @max_public_changes) |> Enum.map(&public_change/1)
    if changes == [], do: acc, else: Map.put(acc, :changes, changes)
  end

  defp put_public_field(acc, :changed_files, values) when is_list(values) do
    values =
      values
      |> Enum.filter(&is_binary/1)
      |> Enum.take(@max_public_paths)
      |> Enum.map(&public_scalar/1)

    if values == [], do: acc, else: Map.put(acc, :changed_files, values)
  end

  defp put_public_field(acc, :tests, values) when is_list(values) do
    values =
      values
      |> Enum.take(@max_public_paths)
      |> Enum.map(fn
        %{command: command} = test ->
          %{command: public_scalar(command)}
          |> put_public_field(:status, Map.get(test, :status) || Map.get(test, "status"))
          |> put_public_field(
            :evidence_id,
            Map.get(test, :evidence_id) || Map.get(test, "evidence_id")
          )

        %{"command" => command} = test ->
          %{command: public_scalar(command)}
          |> put_public_field(:status, Map.get(test, :status) || Map.get(test, "status"))
          |> put_public_field(
            :evidence_id,
            Map.get(test, :evidence_id) || Map.get(test, "evidence_id")
          )

        _ ->
          %{command: :present}
      end)

    if values == [], do: acc, else: Map.put(acc, :tests, values)
  end

  defp put_public_field(acc, :git, %{outcome: _outcome} = git) do
    git =
      Enum.reduce(@public_git_keys, %{}, fn key, public_git ->
        case git_value(git, key) do
          nil -> public_git
          value -> Map.put(public_git, key, public_scalar(value))
        end
      end)

    if map_size(git) == 0, do: acc, else: Map.put(acc, :git, git)
  end

  defp put_public_field(acc, :git, %{"outcome" => _outcome} = git) do
    put_public_field(acc, :git, atomize_git(git))
  end

  defp put_public_field(acc, :owner_ref, value) when is_map(value) do
    case public_owner_ref(value) do
      nil -> acc
      owner_ref -> Map.put(acc, :owner_ref, owner_ref)
    end
  end

  defp put_public_field(acc, :contract, %{version: version}) when is_binary(version),
    do: Map.put(acc, :contract, %{version: public_scalar(version)})

  defp put_public_field(acc, :redaction, %{applied: true} = redaction) do
    Map.put(acc, :redaction, %{applied: true, omitted: Map.get(redaction, :omitted, [])})
  end

  defp put_public_field(acc, :artifacts, artifacts) when is_list(artifacts) do
    artifacts =
      artifacts
      |> Enum.take(@max_public_changes)
      |> Enum.map(fn
        %{path: path, kind: kind} ->
          %{path: public_scalar(path), kind: public_scalar(kind)}

        %{"path" => path, "kind" => kind} ->
          %{path: public_scalar(path), kind: public_scalar(kind)}

        _ ->
          %{kind: :present}
      end)

    if artifacts == [], do: acc, else: Map.put(acc, :artifacts, artifacts)
  end

  defp put_public_field(acc, key, value)
       when key in [
              :status,
              :result,
              :error,
              :retryable,
              :timed_out,
              :cancelled,
              :output_truncated,
              :exit_code,
              :command_id,
              :reason,
              :path,
              :kind,
              :index,
              :name,
              :kind,
              :source,
              :evidence_id,
              :receipt_id,
              :handoff_id,
              :head_sha,
              :base_branch,
              :head_branch,
              :repository,
              :workspace_id,
              :owner_ref,
              :runtime_id,
              :worker_id,
              :release_sha,
              :idempotency_key,
              :evidence_ref,
              :decision_id,
              :session_id,
              :workcell_id,
              :task_id,
              :lease_id,
              :correlation_id,
              :occurred_at
            ] do
    case public_scalar(value) do
      nil -> acc
      scalar -> Map.put(acc, key, scalar)
    end
  end

  defp put_public_field(acc, _key, _value), do: acc

  defp public_change(%{} = change) do
    %{}
    |> put_public_field(:path, Map.get(change, :path))
    |> put_public_field(:kind, Map.get(change, :kind))
  end

  defp public_change(_change), do: %{kind: :present}

  defp public_scalar(value) when is_binary(value), do: String.slice(value, 0, 256)

  defp public_scalar(value)
       when is_atom(value) or is_number(value) or is_boolean(value),
       do: value

  defp public_scalar(_value), do: nil

  defp public_owner_ref(value) do
    case OwnerRef.normalize(value) do
      {:ok, owner_ref} -> owner_ref
      {:error, _reason} -> nil
    end
  end

  defp git_value(git, key), do: Map.get(git, key, Map.get(git, Atom.to_string(key)))

  defp atomize_git(git) do
    Enum.reduce(@public_git_keys, %{}, fn key, acc ->
      case git_value(git, key) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp public_scope(%Scope{} = scope), do: Scope.public(scope)
  defp public_scope(_scope), do: nil

  defp public_receipt(receipt) when is_map(receipt) do
    Receipt.public(receipt)
  end

  defp public_receipt(_receipt), do: nil

  defp receipt_from(%{handoff_id: id, head_sha: sha} = result)
       when is_binary(id) and is_binary(sha),
       do: result

  defp receipt_from(%{"handoff_id" => id, "head_sha" => sha} = result)
       when is_binary(id) and is_binary(sha),
       do: result

  defp receipt_from(%{} = result) do
    if frozen_receipt?(result), do: result, else: completed_receipt(result)
  end

  defp receipt_from(_result), do: nil

  defp completed_receipt(%{completed: completed}) when is_list(completed) do
    completed
    |> Enum.reverse()
    |> Enum.find_value(&receipt_from(Map.get(&1, :result) || %{}))
  end

  defp completed_receipt(_result), do: nil

  defp frozen_receipt?(result) do
    handoff_id = Map.get(result, :handoff_id) || Map.get(result, "handoff_id")
    idempotency = Map.get(result, :idempotency) || Map.get(result, "idempotency")
    git = Map.get(result, :git) || Map.get(result, "git")
    head_sha = if is_map(git), do: Map.get(git, :head_sha) || Map.get(git, "head_sha")

    is_binary(handoff_id) and is_map(idempotency) and is_map(git) and is_binary(head_sha)
  end

  defp owner_ref(nil, workspace_id), do: OwnerRef.for_workspace(workspace_id)

  defp owner_ref(value, workspace_id) do
    case OwnerRef.normalize(value) do
      {:ok, owner_ref} -> owner_ref
      {:error, _reason} -> OwnerRef.for_workspace(workspace_id)
    end
  end

  defp id_suffix do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
