defmodule Casein.Agents.JidoLifecycle.ReadModel do
  @moduledoc """
  Fold a durable Jido/OpenCode event stream into one honest worker snapshot.

  Completion and idle are never inferred from model text or missing pane
  output. Human input stays human. Evidence is marked partial or stale.
  """

  alias Casein.Agents.AgentEvent
  alias Casein.Agents.JidoLifecycle.Envelope
  alias Casein.Agents.JidoPod.Attempt

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

  @terminal Enum.filter(@states, &Attempt.terminal?/1)

  @type snapshot :: %{
          workspace_id: String.t() | nil,
          task_id: String.t() | nil,
          attempt_id: String.t() | nil,
          worker_id: String.t() | nil,
          worktree_path: String.t() | nil,
          runtime: :jido | :opencode,
          headless: boolean(),
          state: atom() | nil,
          last_progress: map() | nil,
          blocker: map() | nil,
          result: map() | nil,
          evidence: map() | nil,
          handoff: map() | nil,
          error: term(),
          retryable?: boolean(),
          checkpoint: map() | nil,
          correlation_id: String.t() | nil,
          sequence: non_neg_integer(),
          updated_at: DateTime.t() | nil,
          pane_id: String.t() | nil,
          resume_token: String.t() | nil
        }

  @spec empty() :: snapshot()
  def empty do
    %{
      workspace_id: nil,
      task_id: nil,
      attempt_id: nil,
      worker_id: nil,
      worktree_path: nil,
      runtime: :jido,
      headless: true,
      state: nil,
      last_progress: nil,
      blocker: nil,
      result: nil,
      evidence: nil,
      handoff: nil,
      error: nil,
      retryable?: false,
      checkpoint: nil,
      correlation_id: nil,
      sequence: 0,
      updated_at: nil,
      pane_id: nil,
      resume_token: nil
    }
  end

  @spec fold([AgentEvent.t() | map()]) :: snapshot()
  def fold(events) when is_list(events) do
    events
    |> Enum.sort_by(&sort_key/1, :asc)
    |> Enum.reduce(empty(), &apply_event/2)
  end

  defp sort_key(%AgentEvent{} = event) do
    {event.source_sequence || 0, event.occurred_at || event.inserted_at, event.id || ""}
  end

  defp sort_key(%{sequence: sequence} = event) do
    {sequence, Map.get(event, :timestamp) || Map.get(event, :occurred_at),
     Map.get(event, :id, "")}
  end

  defp apply_event(%AgentEvent{} = event, snapshot) do
    apply_typed(event.event_type, payload(event), snapshot, event)
  end

  defp apply_event(%{event_type: type} = event, snapshot) do
    apply_typed(type, Map.get(event, :payload) || %{}, snapshot, event)
  end

  defp apply_typed("jido.lifecycle", payload, snapshot, event) do
    state = atomize(payload["state"] || payload[:state])

    snapshot
    |> identity(event, payload)
    |> Map.put(:state, honest_state(state, snapshot.runtime))
    |> Map.put(:error, payload["error"] || payload[:error] || snapshot.error)
    |> Map.put(:retryable?, payload["retryable"] == true)
    |> maybe_clear_blocker(state)
  end

  defp apply_typed("jido.progress", payload, snapshot, event) do
    summary = Envelope.bound_summary(payload["summary"] || payload[:summary])

    snapshot
    |> identity(event, payload)
    |> Map.put(:last_progress, %{
      summary: summary,
      at: occurred_at(event),
      sequence: sequence(event),
      partial?: payload["partial"] == true
    })
    |> stale_evidence()
  end

  defp apply_typed("jido.checkpoint", payload, snapshot, event) do
    snapshot
    |> identity(event, payload)
    |> Map.put(:checkpoint, %{
      next_index: payload["next_index"] || payload[:next_index] || 0,
      completed_count: payload["completed_count"] || payload[:completed_count] || 0,
      sequence: sequence(event)
    })
  end

  defp apply_typed("jido.action", payload, snapshot, event) do
    result = atomize(payload["result"] || payload[:result])

    snapshot
    |> identity(event, payload)
    |> Map.put(:error, payload["error"] || payload[:error] || snapshot.error)
    |> Map.put(
      :retryable?,
      result in [:timeout, :provider_failure] or payload["retryable"] == true
    )
    |> Map.put(:last_progress, %{
      summary:
        Envelope.bound_summary(payload["summary"] || payload[:action] || event_summary(event)),
      at: occurred_at(event),
      sequence: sequence(event),
      action: payload["action"] || payload[:action],
      result: result
    })
  end

  defp apply_typed("jido.blocked", payload, snapshot, event) do
    request_id = payload["request_id"] || payload[:request_id]

    snapshot
    |> identity(event, payload)
    |> Map.put(:state, :awaiting_human)
    |> Map.put(:blocker, %{
      request_id: request_id,
      kind: payload["kind"] || payload[:kind] || "clarification",
      resume_token: Envelope.resume_token(identity(snapshot, event, payload)),
      prompt_present: payload["prompt_present"] == true,
      at: occurred_at(event)
    })
  end

  defp apply_typed("jido.result", payload, snapshot, event) do
    snapshot
    |> identity(event, payload)
    |> Map.put(:result, %{
      status: payload["status"] || payload[:status],
      summary: Envelope.bound_summary(payload["summary"] || payload[:summary]),
      complete?: false,
      at: occurred_at(event)
    })
  end

  defp apply_typed("jido.evidence", payload, snapshot, event) do
    paths = List.wrap(payload["paths"] || payload[:paths]) |> Enum.filter(&is_binary/1)

    snapshot
    |> identity(event, payload)
    |> Map.put(:evidence, %{
      paths: Enum.take(paths, 32),
      verification_ref: payload["verification_ref"] || payload[:verification_ref],
      freshness: freshness(payload, snapshot),
      at: occurred_at(event)
    })
  end

  defp apply_typed("jido.handoff", payload, snapshot, event) do
    handoff = payload["handoff"] || payload[:handoff] || %{}

    head_sha =
      payload["head_sha"] || payload[:head_sha] || handoff["head_sha"] || handoff[:head_sha]

    snapshot
    |> identity(event, payload)
    |> Map.put(:handoff, handoff)
    |> Map.put(:last_progress, %{
      summary:
        Envelope.bound_summary(payload["summary"] || payload[:summary] || "worker branch pushed"),
      at: occurred_at(event),
      sequence: sequence(event),
      action: "git_push",
      pushed?: (payload["pushed"] || payload[:pushed]) == true,
      head_sha: head_sha,
      idempotency_key: payload["idempotency_key"] || payload[:idempotency_key]
    })
  end

  defp apply_typed("jido.human_resolved", payload, snapshot, event) do
    snapshot
    |> identity(event, payload)
    |> Map.put(:blocker, nil)
    |> Map.put(:state, if(snapshot.state == :awaiting_human, do: :running, else: snapshot.state))
    |> put_in([:result], snapshot.result)
    |> Map.put(:last_progress, %{
      summary: "human resolved",
      at: occurred_at(event),
      sequence: sequence(event),
      request_id: payload["request_id"] || payload[:request_id]
    })
  end

  defp apply_typed("agent.state_changed", payload, snapshot, event) do
    reported = atomize(payload["state"] || payload[:state] || event_status(event))

    snapshot
    |> identity(event, payload)
    |> Map.merge(%{
      runtime: :opencode,
      headless: false,
      pane_id: pane_id(event),
      state: opencode_state(reported)
    })
  end

  defp apply_typed(_type, _payload, snapshot, _event), do: snapshot

  defp identity(snapshot, event, payload) do
    workspace_id = workspace_id(event) || snapshot.workspace_id
    attempt_id = attempt_id(event, payload) || snapshot.attempt_id
    worker_id = worker_id(event, payload) || snapshot.worker_id || attempt_id

    %{
      snapshot
      | workspace_id: workspace_id,
        task_id: payload["task_id"] || payload[:task_id] || snapshot.task_id,
        attempt_id: attempt_id,
        worker_id: worker_id,
        worktree_path:
          payload["worktree_path"] || payload[:worktree_path] || snapshot.worktree_path,
        runtime: runtime(event, payload, snapshot),
        headless: headless?(event, payload, snapshot),
        correlation_id:
          correlation_id(event) || payload["correlation_id"] || snapshot.correlation_id,
        sequence: max(snapshot.sequence, sequence(event)),
        updated_at: occurred_at(event) || snapshot.updated_at,
        resume_token:
          Envelope.resume_token(%{workspace_id: workspace_id, attempt_id: attempt_id}) ||
            snapshot.resume_token
    }
  end

  defp honest_state(state, :jido) when state in @terminal, do: state
  defp honest_state(state, :jido) when state in @states, do: state
  defp honest_state(state, :opencode), do: opencode_state(state)
  defp honest_state(_state, _runtime), do: nil

  defp opencode_state(:working), do: :running
  defp opencode_state(:blocked), do: :awaiting_human
  defp opencode_state(:awaiting_input), do: :awaiting_human
  defp opencode_state(:done), do: :done
  defp opencode_state(:idle), do: :idle
  defp opencode_state(:errored), do: :failed
  defp opencode_state(:stalled), do: :stalled
  defp opencode_state(other), do: other

  defp maybe_clear_blocker(snapshot, state) when state in @terminal,
    do: %{snapshot | blocker: nil}

  defp maybe_clear_blocker(snapshot, state) when state in [:running, :retrying, :queued],
    do: %{snapshot | blocker: nil}

  defp maybe_clear_blocker(snapshot, _state), do: snapshot

  defp stale_evidence(%{evidence: %{freshness: freshness} = evidence} = snapshot)
       when freshness in [:current, "current"] do
    %{snapshot | evidence: Map.put(evidence, :freshness, :stale)}
  end

  defp stale_evidence(snapshot), do: snapshot

  defp freshness(payload, snapshot) do
    cond do
      payload["freshness"] in [:partial, "partial"] or payload["partial"] == true -> :partial
      snapshot.last_progress != nil -> :stale
      true -> :current
    end
  end

  defp payload(%AgentEvent{payload: payload}) when is_map(payload), do: payload
  defp payload(_), do: %{}

  defp workspace_id(%AgentEvent{workspace_id: id}), do: id
  defp workspace_id(%{workspace_id: id}), do: id
  defp workspace_id(_), do: nil

  defp attempt_id(%AgentEvent{agent_session_id: id}, payload) do
    payload["attempt_id"] || payload[:attempt_id] || id
  end

  defp attempt_id(event, payload) do
    payload["attempt_id"] || payload[:attempt_id] || Map.get(event, :attempt_id)
  end

  defp worker_id(%AgentEvent{agent_session_id: id, pane_id: pane}, payload) do
    payload["worker_id"] || payload[:worker_id] || id || pane
  end

  defp worker_id(event, payload) do
    payload["worker_id"] || payload[:worker_id] || Map.get(event, :worker_id)
  end

  defp correlation_id(%AgentEvent{correlation_id: id}), do: id
  defp correlation_id(%{correlation_id: id}), do: id
  defp correlation_id(_), do: nil

  defp sequence(%AgentEvent{source_sequence: n}) when is_integer(n), do: n
  defp sequence(%{sequence: n}) when is_integer(n), do: n
  defp sequence(_), do: 0

  defp occurred_at(%AgentEvent{occurred_at: at}), do: at
  defp occurred_at(%{timestamp: at}), do: at
  defp occurred_at(%{occurred_at: at}), do: at
  defp occurred_at(_), do: nil

  defp pane_id(%AgentEvent{pane_id: id}), do: id
  defp pane_id(%{pane_id: id}), do: id
  defp pane_id(_), do: nil

  defp event_status(%AgentEvent{status: status}), do: status
  defp event_status(_), do: nil

  defp event_summary(%AgentEvent{summary: summary}), do: summary
  defp event_summary(_), do: ""

  defp runtime(%AgentEvent{producer: "agent"}, _payload, _snapshot), do: :opencode

  defp runtime(%{runtime: runtime}, _payload, _snapshot) when runtime in [:jido, :opencode],
    do: runtime

  defp runtime(_event, payload, snapshot) do
    case payload["runtime"] || payload[:runtime] do
      :opencode -> :opencode
      "opencode" -> :opencode
      :jido -> :jido
      "jido" -> :jido
      _ -> snapshot.runtime
    end
  end

  defp headless?(_event, payload, snapshot) do
    case payload["headless"] || payload[:headless] do
      false -> false
      true -> true
      _ -> snapshot.headless
    end
  end

  defp atomize(value) when is_atom(value), do: value

  defp atomize(value) when is_binary(value) do
    allowed =
      ~w(admitted queued running awaiting_human retrying completed failed cancelled timed_out provider_unavailable working blocked done idle errored stalled awaiting_input timeout provider_failure ok denied)a

    Enum.find(allowed, fn name -> Atom.to_string(name) == value end)
  end

  defp atomize(_), do: nil
end
