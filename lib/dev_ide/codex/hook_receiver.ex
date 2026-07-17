defmodule DevIDE.Codex.HookReceiver do
  @moduledoc "Authenticated ingestion boundary for Codex CLI lifecycle hooks."

  alias DevIDE.Codex.{EventHub, HookProtocol}
  alias DevIDE.Terminals.AgentState

  @spec ingest(String.t(), map(), keyword()) :: {:ok, [DevIDE.Codex.Event.t()]} | {:error, term()}
  def ingest(workspace_id, payload, opts \\ [])
      when is_binary(workspace_id) and is_map(payload) do
    transport = Keyword.get(opts, :transport, :hook)

    session_id =
      payload["session_id"] || payload["sessionId"] || payload["thread_id"] ||
        payload["threadId"] || payload["thread-id"] || Keyword.get(opts, :session_id)

    runtime_id = "#{transport}:#{session_id || Ecto.UUID.generate()}"

    context = %{
      workspace_id: workspace_id,
      runtime_id: runtime_id,
      transport: transport,
      sequence: 1,
      occurred_at: DateTime.utc_now(),
      session_id: session_id,
      turn_id: payload["turn_id"] || payload["turnId"] || payload["turn-id"]
    }

    with {:ok, events} <- HookProtocol.normalize(payload, context),
         {:ok, routed} <- publish_all(events) do
      report_pane_state(workspace_id, payload, opts)
      {:ok, routed}
    end
  end

  defp publish_all(events) do
    Enum.reduce_while(events, {:ok, []}, fn event, {:ok, routed} ->
      case EventHub.publish(event) do
        {:ok, event} -> {:cont, {:ok, [event | routed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, routed} -> {:ok, Enum.reverse(routed)}
      error -> error
    end
  end

  defp report_pane_state(workspace_id, payload, opts) do
    with session when is_binary(session) <- Keyword.get(opts, :tmux_session),
         pane when is_binary(pane) <- Keyword.get(opts, :pane),
         state when state in [:working, :blocked, :done] <- semantic_state(payload) do
      AgentState.report(workspace_id, session, pane, state, state_message(payload), source: :hook)
    else
      _other -> :ok
    end
  end

  defp semantic_state(payload) do
    case payload["hook_event_name"] || payload["hookEventName"] || payload["type"] do
      event when event in ["UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart"] ->
        :working

      "PermissionRequest" ->
        :blocked

      event when event in ["Stop", "SubagentStop", "agent-turn-complete"] ->
        :done

      _other ->
        nil
    end
  end

  defp state_message(payload) do
    payload["reason"] || payload["last-assistant-message"] || payload["tool_name"]
  end
end
