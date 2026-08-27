defmodule Casein.Agents.JidoLifecycle.Projector do
  @moduledoc false

  alias Casein.Agents.{Activity, AgentEvents, Inbox}
  alias Casein.Agents.Inbox.Address
  alias Casein.Agents.JidoLifecycle.Envelope
  alias Casein.Audit
  alias Phoenix.PubSub

  @topic_prefix "jido_lifecycle:"

  @spec persist(Envelope.t(), keyword()) ::
          {:ok, term(), :inserted | :duplicate} | {:error, term()}
  def persist(envelope, opts \\ []) do
    source_event_id = Keyword.fetch!(opts, :source_event_id)
    privacy = Keyword.get(opts, :privacy_class, "metadata")
    status = Keyword.get(opts, :status)
    notify_inbox? = Keyword.get(opts, :inbox, false)
    audit? = Keyword.get(opts, :audit, false)
    live? = Keyword.get(opts, :live, true)

    attrs = %{
      workspace_id: envelope.workspace_id,
      stream_id: stream_id(envelope),
      producer: producer(envelope),
      ingress: ingress(envelope),
      source_event_id: source_event_id,
      source_sequence: envelope.sequence,
      event_type: envelope.event_type,
      privacy_class: privacy,
      agent_session_id: envelope.session_id || envelope.attempt_id || envelope.worker_id,
      actor_id: Keyword.get(opts, :actor_id),
      status: status || envelope.event_type,
      summary: Keyword.get(opts, :summary) || default_summary(envelope),
      correlation_id: envelope.correlation_id,
      payload: persist_payload(envelope),
      occurred_at: envelope.timestamp
    }

    case AgentEvents.append(attrs) do
      {:ok, event, :inserted} = result ->
        if live?, do: record_activity(envelope, event, opts)
        if audit?, do: record_audit(envelope, opts)
        if notify_inbox?, do: notify_inbox(envelope, opts)
        broadcast(envelope)
        result

      other ->
        other
    end
  end

  def topic(workspace_id), do: @topic_prefix <> workspace_id

  defp stream_id(%{runtime: :opencode, worker_id: worker}) when is_binary(worker),
    do: "opencode:#{worker}"

  defp stream_id(%{attempt_id: attempt}) when is_binary(attempt), do: "jido:#{attempt}"
  defp stream_id(%{worker_id: worker}) when is_binary(worker), do: "jido:#{worker}"
  defp stream_id(%{workspace_id: workspace}), do: "jido:workspace:#{workspace}"

  defp producer(%{runtime: :opencode}), do: "agent"
  defp producer(_), do: "jido"

  defp ingress(%{runtime: :opencode}), do: "agent_state"
  defp ingress(_), do: "jido_lifecycle"

  defp persist_payload(envelope) do
    %{
      "schema_version" => 1,
      "workspace_id" => envelope.workspace_id,
      "session_id" => envelope.session_id,
      "workcell_id" => envelope.workcell_id,
      "task_id" => envelope.task_id,
      "attempt_id" => envelope.attempt_id,
      "worker_id" => envelope.worker_id,
      "lease_id" => envelope.lease_id,
      "handoff_id" => envelope.handoff_id,
      "action" => envelope.action,
      "correlation_id" => envelope.correlation_id,
      "sequence" => envelope.sequence,
      "runtime" => Atom.to_string(envelope.runtime),
      "headless" => envelope.headless
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
    |> Map.merge(envelope.payload)
  end

  defp default_summary(envelope) do
    action = envelope.action || envelope.event_type
    Envelope.bound_summary("#{action} #{envelope.attempt_id || envelope.worker_id}")
  end

  defp record_activity(envelope, event, opts) do
    status = if Keyword.get(opts, :error, false), do: :error, else: :ok

    Activity.record(%{
      id: event.id,
      workspace_id: envelope.workspace_id,
      source: :jido_lifecycle,
      tool: envelope.action || envelope.event_type,
      summary: event.summary,
      status: status,
      inserted_at: event.occurred_at,
      metadata: %{
        event_type: envelope.event_type,
        task_id: envelope.task_id,
        attempt_id: envelope.attempt_id,
        worker_id: envelope.worker_id,
        correlation_id: envelope.correlation_id,
        sequence: envelope.sequence,
        runtime: envelope.runtime,
        headless: envelope.headless,
        resume_token: Envelope.resume_token(envelope)
      }
    })
  end

  defp record_audit(envelope, opts) do
    Audit.emit!(%{
      workspace_id: envelope.workspace_id,
      actor_id: Keyword.get(opts, :actor_id) || "jido",
      action: "agent.jido_" <> String.replace(envelope.event_type, ".", "_"),
      source: "jido_lifecycle",
      tool: envelope.action || envelope.event_type,
      metadata: %{
        task_id: envelope.task_id,
        attempt_id: envelope.attempt_id,
        correlation_id: envelope.correlation_id,
        sequence: envelope.sequence,
        result: envelope.payload["result"] || envelope.payload["state"]
      }
    })
  end

  defp notify_inbox(envelope, opts) do
    worktree = envelope.payload["worktree_path"]

    if is_binary(worktree) and worktree != "" do
      Inbox.send(%{
        workspace_id: envelope.workspace_id,
        to: Address.for_worktree(worktree),
        body: Keyword.get(opts, :inbox_body) || "Headless worker is awaiting human input",
        message_id: envelope.payload["request_id"] || Envelope.resume_token(envelope),
        from: "worktree:" <> worktree
      })
    end
  end

  defp broadcast(envelope) do
    PubSub.broadcast(
      Casein.PubSub,
      topic(envelope.workspace_id),
      {:jido_lifecycle, envelope}
    )
  end
end
