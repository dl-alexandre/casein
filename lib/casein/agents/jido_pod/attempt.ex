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
          workspace_id: String.t(),
          task_id: String.t(),
          worktree_path: String.t() | nil,
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
          finished_at: DateTime.t() | nil
        }

  @enforce_keys [
    :id,
    :workspace_id,
    :task_id,
    :state,
    :inserted_at,
    :updated_at,
    :last_progress_at
  ]
  defstruct [
    :id,
    :workspace_id,
    :task_id,
    :worktree_path,
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
    lease?: false,
    cancel_requested?: false,
    actions: [],
    next_index: 0,
    completed: [],
    retries: 0,
    max_retries: 1,
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

    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      workspace_id: Map.fetch!(attrs, :workspace_id),
      task_id: Map.fetch!(attrs, :task_id),
      worktree_path: Map.get(attrs, :worktree_path),
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
        cancel_requested?: Keyword.get(opts, :cancel_requested?, attempt.cancel_requested?),
        next_index: Keyword.get(opts, :next_index, attempt.next_index),
        completed: Keyword.get(opts, :completed, attempt.completed),
        retries: Keyword.get(opts, :retries, attempt.retries),
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
      workspace_id: attempt.workspace_id,
      task_id: attempt.task_id,
      worktree_path: attempt.worktree_path,
      state: attempt.state,
      reason: attempt.reason,
      result: attempt.result,
      error: attempt.error,
      retries: attempt.retries,
      next_index: attempt.next_index,
      completed_count: length(attempt.completed),
      last_progress_at: attempt.last_progress_at,
      inserted_at: attempt.inserted_at,
      updated_at: attempt.updated_at,
      started_at: attempt.started_at,
      finished_at: attempt.finished_at,
      headless: true
    }
  end

  defp started_at(%{started_at: nil}, :running, now), do: now
  defp started_at(%{started_at: started}, _state, _now), do: started

  defp finished_at(attempt, state, now) do
    if terminal?(state), do: attempt.finished_at || now, else: nil
  end
end
