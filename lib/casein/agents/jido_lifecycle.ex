defmodule Casein.Agents.JidoLifecycle do
  @moduledoc """
  Project headless Jido lifecycle into Casein's existing read models (#1016).

  Pod and action contracts stay unchanged. This module writes a stable
  redacted envelope, then folds it into agent events, activity, audit,
  inbox, and a replayable worker snapshot. OpenCode pane reports use the
  same snapshot shape.
  """

  alias Casein.Agents.{AgentEvent, AgentEvents, JidoPod}
  alias Casein.Agents.JidoLifecycle.{Envelope, Projector, ReadModel}

  @type snapshot :: ReadModel.snapshot()

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(Casein.PubSub, Projector.topic(workspace_id))
  end

  @spec resume_token(String.t(), String.t()) :: String.t()
  def resume_token(workspace_id, attempt_id)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    Envelope.resume_token(%{workspace_id: workspace_id, attempt_id: attempt_id})
  end

  @spec ingest_attempt(map()) :: :ok
  def ingest_attempt(%{workspace_id: workspace_id, attempt_id: attempt_id} = attempt)
      when is_binary(workspace_id) and is_binary(attempt_id) do
    prior = snapshot_for(workspace_id, attempt_id)
    sequence = prior.sequence + 1
    state = attempt[:state] || attempt["state"]

    if prior.state != state do
      persist_lifecycle(attempt, sequence, state)
    end

    if checkpoint_changed?(prior, attempt) do
      persist_checkpoint(attempt, sequence + if(prior.state != state, do: 1, else: 0))
    end

    :ok
  rescue
    _ -> :ok
  end

  def ingest_attempt(_attempt), do: :ok

  @spec ingest_action(String.t(), map(), map()) :: :ok
  def ingest_action(name, payload, ctx)
      when is_binary(name) and is_map(payload) and is_map(ctx) do
    workspace_id = ctx[:workspace_id] || payload[:workspace_id]
    attempt_id = ctx[:attempt_id] || payload[:attempt_id]

    if is_binary(workspace_id) do
      prior = snapshot_for(workspace_id, attempt_id || workspace_id)
      sequence = prior.sequence + 1

      cond do
        name in ~w(request_clarification request_human_input) ->
          persist_blocked(name, payload, ctx, sequence)

        name == "report_progress" ->
          persist_named("jido.progress", name, payload, ctx, sequence,
            summary: Envelope.bound_summary(payload[:summary]),
            extra: %{
              "summary" => Envelope.bound_summary(payload[:summary]),
              "partial" => true
            }
          )

        name == "report_result" ->
          persist_named("jido.result", name, payload, ctx, sequence,
            audit: true,
            extra: %{
              "status" => payload[:status],
              "summary" => Envelope.bound_summary(payload[:summary]),
              "complete" => false
            }
          )

        name == "handoff_evidence" ->
          persist_named("jido.evidence", name, payload, ctx, sequence,
            audit: true,
            extra: %{
              "paths" => List.wrap(payload[:paths]),
              "verification_ref" => payload[:verification_ref],
              "partial" => payload[:verification_ref] in [nil, ""],
              "summary" => Envelope.bound_summary(payload[:summary]),
              "repository" => payload[:repository],
              "pull_request" => payload[:pull_request],
              "head_sha" => payload[:head_sha],
              "review_thread_ids" => List.wrap(payload[:review_thread_ids]),
              "handoff_target" => payload[:handoff_target],
              "review_resolution" => payload[:review_resolution],
              "merge_policy" => payload[:merge_policy]
            }
          )

        true ->
          persist_named("jido.action", name, payload, ctx, sequence,
            error: payload[:result] not in [:ok, nil],
            extra: %{
              "result" => payload[:result],
              "error" => payload[:error],
              "retryable" => payload[:retryable] == true,
              "summary" => Envelope.bound_summary(payload[:summary] || name)
            }
          )
      end
    end

    :ok
  rescue
    _ -> :ok
  end

  def ingest_action(_name, _payload, _ctx), do: :ok

  @spec ingest_opencode(map()) :: :ok
  def ingest_opencode(attrs) when is_map(attrs) do
    workspace_id = attrs[:workspace_id] || attrs["workspace_id"]
    worker_id = attrs[:agent_session_id] || attrs[:pane_id] || attrs["pane_id"]

    if is_binary(workspace_id) and is_binary(worker_id) do
      prior = snapshot_for(workspace_id, worker_id)
      reported = attrs[:state] || attrs["state"]

      envelope =
        Envelope.build(%{
          workspace_id: workspace_id,
          task_id: attrs[:task_id],
          attempt_id: worker_id,
          worker_id: worker_id,
          correlation_id: attrs[:agent_session_id] || worker_id,
          sequence: prior.sequence + 1,
          event_type: "agent.state_changed",
          runtime: :opencode,
          headless: false,
          payload: %{
            "state" => reported,
            "prior_state" => attrs[:prior_state],
            "pane_id" => attrs[:pane_id],
            "tmux_session_id" => attrs[:tmux_session_id]
          }
        })

      Projector.persist(envelope,
        source_event_id: Envelope.source_event_id(envelope, "#{reported}:#{prior.sequence + 1}"),
        status: reported,
        live: false
      )
    end

    :ok
  rescue
    _ -> :ok
  end

  def ingest_opencode(_attrs), do: :ok

  @spec get(String.t(), String.t()) :: {:ok, snapshot()} | {:error, :not_found}
  def get(workspace_id, worker_id)
      when is_binary(workspace_id) and is_binary(worker_id) do
    case snapshot_for(workspace_id, worker_id) do
      %{state: nil} -> {:error, :not_found}
      snapshot -> {:ok, snapshot}
    end
  end

  @spec list(String.t()) :: [snapshot()]
  def list(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> AgentEvents.list_by_event_types([
      "jido.lifecycle",
      "jido.progress",
      "jido.checkpoint",
      "jido.action",
      "jido.blocked",
      "jido.result",
      "jido.evidence",
      "jido.human_resolved",
      "agent.state_changed"
    ])
    |> Enum.group_by(&worker_key/1)
    |> Enum.map(fn {_key, events} -> ReadModel.fold(Enum.reverse(events)) end)
    |> Enum.reject(&is_nil(&1.state))
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  @spec replay(String.t(), String.t()) :: snapshot()
  def replay(workspace_id, worker_id)
      when is_binary(workspace_id) and is_binary(worker_id) do
    snapshot_for(workspace_id, worker_id)
  end

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def answer(workspace_id, attrs) when is_binary(workspace_id) and is_map(attrs) do
    attempt_id = attrs[:attempt_id] || attrs["attempt_id"]

    with :ok <- ensure_human(attrs),
         {:ok, snapshot} <- get(workspace_id, attempt_id),
         :ok <- ensure_awaiting(snapshot) do
      request_id =
        attrs[:request_id] || attrs["request_id"] ||
          get_in(snapshot, [:blocker, :request_id])

      persist_human_resolved(workspace_id, snapshot, attrs, request_id)
      resume = maybe_resume(workspace_id, attempt_id)
      {:ok, %{snapshot: replay(workspace_id, attempt_id), resume: resume}}
    end
  end

  def answer(_workspace_id, _attrs), do: {:error, :invalid}

  defp persist_lifecycle(attempt, sequence, state) do
    envelope =
      Envelope.build(%{
        workspace_id: attempt.workspace_id,
        task_id: attempt[:task_id],
        attempt_id: attempt.attempt_id,
        worker_id: attempt.attempt_id,
        correlation_id: attempt[:task_id] || attempt.attempt_id,
        sequence: sequence,
        timestamp: attempt[:updated_at] || attempt[:last_progress_at],
        event_type: "jido.lifecycle",
        runtime: :jido,
        headless: true,
        payload: %{
          "state" => state,
          "reason" => attempt[:reason],
          "error" => attempt[:error],
          "retries" => attempt[:retries],
          "worktree_path" => attempt[:worktree_path],
          "retryable" => state in [:timed_out, :provider_unavailable]
        }
      })

    Projector.persist(envelope,
      source_event_id: Envelope.source_event_id(envelope, "#{state}:#{sequence}"),
      status: state,
      audit: state in [:cancelled, :timed_out, :failed, :completed, :provider_unavailable],
      error: state in [:failed, :timed_out, :provider_unavailable],
      summary: Envelope.bound_summary("attempt #{attempt.attempt_id} #{state}")
    )
  end

  defp persist_checkpoint(attempt, sequence) do
    envelope =
      Envelope.build(%{
        workspace_id: attempt.workspace_id,
        task_id: attempt[:task_id],
        attempt_id: attempt.attempt_id,
        worker_id: attempt.attempt_id,
        correlation_id: attempt[:task_id] || attempt.attempt_id,
        sequence: sequence,
        timestamp: attempt[:last_progress_at],
        event_type: "jido.checkpoint",
        runtime: :jido,
        headless: true,
        payload: %{
          "next_index" => attempt[:next_index] || 0,
          "completed_count" => attempt[:completed_count] || 0,
          "worktree_path" => attempt[:worktree_path]
        }
      })

    Projector.persist(envelope,
      source_event_id:
        Envelope.source_event_id(
          envelope,
          "#{attempt[:next_index] || 0}:#{attempt[:completed_count] || 0}"
        ),
      status: attempt[:state],
      live: false,
      summary: Envelope.bound_summary("checkpoint #{attempt.attempt_id}")
    )
  end

  defp persist_blocked(name, payload, ctx, sequence) do
    request_id = payload[:request_id]
    worktree = ctx[:worktree_path] || payload[:worktree_path]

    envelope =
      action_envelope("jido.blocked", name, payload, ctx, sequence, %{
        "request_id" => request_id,
        "kind" => payload[:kind] || "clarification",
        "prompt_present" =>
          present?(payload[:prompt] || payload[:question]) or
            name in ~w(request_clarification request_human_input),
        "worktree_path" => worktree,
        "resume_token" =>
          Envelope.resume_token(%{
            workspace_id: ctx[:workspace_id] || payload[:workspace_id],
            attempt_id: ctx[:attempt_id] || payload[:attempt_id]
          })
      })

    Projector.persist(envelope,
      source_event_id: Envelope.source_event_id(envelope, "blocked:#{request_id}"),
      privacy_class: "operator_content",
      status: "awaiting_human",
      inbox: true,
      inbox_body: "Headless worker is awaiting human input",
      actor_id: ctx[:principal],
      summary: Envelope.bound_summary("awaiting human #{request_id}")
    )
  end

  defp persist_named(type, name, payload, ctx, sequence, opts) do
    extra = Keyword.get(opts, :extra, %{})

    envelope = action_envelope(type, name, payload, ctx, sequence, extra)

    Projector.persist(envelope,
      source_event_id: Envelope.source_event_id(envelope, "#{name}:#{sequence}"),
      status: payload[:result] || payload[:status] || name,
      audit: Keyword.get(opts, :audit, false),
      error: Keyword.get(opts, :error, false),
      actor_id: ctx[:principal],
      summary: Keyword.get(opts, :summary) || Envelope.bound_summary(name)
    )
  end

  defp persist_human_resolved(workspace_id, snapshot, attrs, request_id) do
    envelope =
      Envelope.build(%{
        workspace_id: workspace_id,
        task_id: snapshot.task_id,
        attempt_id: snapshot.attempt_id,
        worker_id: snapshot.worker_id,
        correlation_id: snapshot.correlation_id,
        sequence: snapshot.sequence + 1,
        event_type: "jido.human_resolved",
        runtime: snapshot.runtime,
        headless: snapshot.headless,
        payload: %{
          "request_id" => request_id,
          "actor_id" => attrs[:actor_id] || attrs["actor_id"],
          "action_id" => attrs[:action_id] || attrs["action_id"]
        }
      })

    Projector.persist(envelope,
      source_event_id: "resolved:#{request_id || snapshot.sequence + 1}",
      status: "resolved",
      audit: true,
      actor_id: attrs[:actor_id] || attrs["actor_id"] || "human",
      summary: Envelope.bound_summary("human resolved #{request_id}")
    )
  end

  defp action_envelope(type, name, payload, ctx, sequence, extra) do
    Envelope.build(%{
      workspace_id: ctx[:workspace_id] || payload[:workspace_id],
      task_id: ctx[:task_id] || payload[:task_id],
      attempt_id: ctx[:attempt_id] || payload[:attempt_id],
      worker_id: ctx[:attempt_id] || payload[:attempt_id],
      action: name,
      correlation_id: ctx[:correlation_id] || payload[:correlation_id],
      sequence: sequence,
      event_type: type,
      runtime: :jido,
      headless: true,
      payload: Map.merge(%{"worktree_path" => ctx[:worktree_path]}, extra)
    })
  end

  defp snapshot_for(workspace_id, worker_id) do
    events = AgentEvents.list_for_session(workspace_id, worker_id, limit: 1_000)
    ReadModel.fold(Enum.reverse(events))
  end

  defp worker_key(%AgentEvent{agent_session_id: id}) when is_binary(id), do: id
  defp worker_key(%AgentEvent{stream_id: stream}), do: stream

  defp checkpoint_changed?(prior, attempt) do
    checkpoint = prior.checkpoint || %{}
    next_index = attempt[:next_index] || 0
    completed = attempt[:completed_count] || 0

    next_index != (checkpoint[:next_index] || 0) or
      completed != (checkpoint[:completed_count] || 0)
  end

  defp ensure_human(attrs) do
    case attrs[:actor_kind] || attrs["actor_kind"] do
      :human -> :ok
      "human" -> :ok
      _ -> {:error, :human_required}
    end
  end

  defp ensure_awaiting(%{state: :awaiting_human}), do: :ok
  defp ensure_awaiting(_snapshot), do: {:error, :not_awaiting_human}

  defp maybe_resume(workspace_id, attempt_id) do
    case JidoPod.resume(workspace_id, attempt_id) do
      {:ok, attempt} -> {:ok, attempt}
      {:error, :not_found} -> {:ok, :no_live_attempt}
      {:error, :not_awaiting_human} -> {:ok, :no_live_attempt}
      other -> other
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
