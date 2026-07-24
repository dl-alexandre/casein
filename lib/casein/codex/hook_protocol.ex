defmodule Casein.Codex.HookProtocol do
  @moduledoc "Normalizes Codex lifecycle-hook and legacy notify payloads."

  alias Casein.Codex.Event

  @spec normalize(map(), map()) :: {:ok, [Event.t()]} | :ignore | {:error, term()}
  def normalize(payload, context) when is_map(payload) do
    case event_name(payload) do
      "SessionStart" -> session_start(payload, context)
      "UserPromptSubmit" -> working_hook(payload, context, "UserPromptSubmit")
      "PreToolUse" -> working_hook(payload, context, "PreToolUse")
      "PermissionRequest" -> permission_request(payload, context)
      "PostToolUse" -> working_hook(payload, context, "PostToolUse")
      "Stop" -> turn_completed(payload, context)
      "SubagentStart" -> subagent(payload, context, :subagent_started)
      "SubagentStop" -> subagent(payload, context, :subagent_stopped)
      "agent-turn-complete" -> turn_completed(payload, context)
      nil -> :ignore
      other -> observed(payload, context, other)
    end
  end

  def normalize(_payload, _context), do: {:error, :invalid_hook_payload}

  defp session_start(payload, context) do
    thread_id = session_id(payload, context)

    {:ok,
     [
       Event.new!(:thread_started, context,
         thread_id: thread_id,
         session_id: thread_id,
         payload:
           %{
             status: :active,
             source: :cli,
             cwd: payload["cwd"],
             model: payload["model"],
             start_source: payload["source"]
           }
           |> compact(),
         metadata: hook_metadata("SessionStart")
       )
     ]}
  end

  defp working_hook(payload, context, name) do
    thread_id = session_id(payload, context)
    turn_id = turn_id(payload, context)

    {:ok,
     [
       Event.new!(:hook_observed, context,
         thread_id: thread_id,
         turn_id: turn_id,
         payload: hook_payload(payload, name, "working"),
         metadata: hook_metadata(name)
       ),
       Event.new!(:thread_status_changed, context,
         thread_id: thread_id,
         turn_id: turn_id,
         payload: %{status: :active, active_flags: []},
         metadata: hook_metadata(name)
       )
     ]}
  end

  defp permission_request(payload, context) do
    thread_id = session_id(payload, context)
    turn_id = turn_id(payload, context)

    {:ok,
     [
       Event.new!(:hook_observed, context,
         thread_id: thread_id,
         turn_id: turn_id,
         payload: hook_payload(payload, "PermissionRequest", "blocked"),
         metadata: hook_metadata("PermissionRequest")
       ),
       Event.new!(:thread_status_changed, context,
         thread_id: thread_id,
         turn_id: turn_id,
         payload: %{status: :active, active_flags: [:waiting_on_approval]},
         metadata: hook_metadata("PermissionRequest")
       )
     ]}
  end

  defp turn_completed(payload, context) do
    name = event_name(payload)
    thread_id = session_id(payload, context)

    {:ok,
     [
       Event.new!(:turn_completed, context,
         thread_id: thread_id,
         turn_id: turn_id(payload, context),
         payload:
           %{
             status: :completed,
             last_message: bounded_string(payload["last-assistant-message"])
           }
           |> compact(),
         metadata: hook_metadata(name)
       )
     ]}
  end

  defp subagent(payload, context, type) do
    agent_id = payload["agent_id"] || payload["agentId"]

    if is_binary(agent_id) and agent_id != "" do
      parent = session_id(payload, context)

      {:ok,
       [
         Event.new!(type, context,
           thread_id: agent_id,
           parent_thread_id: parent,
           turn_id: turn_id(payload, context),
           payload:
             %{
               status: if(type == :subagent_started, do: :active, else: :idle),
               agent_type: payload["agent_type"] || payload["agentType"],
               permission_mode: payload["permission_mode"]
             }
             |> compact(),
           metadata: hook_metadata(event_name(payload))
         )
       ]}
    else
      {:error, :subagent_id_required}
    end
  end

  defp observed(payload, context, name) do
    {:ok,
     [
       Event.new!(:hook_observed, context,
         thread_id: session_id(payload, context),
         turn_id: turn_id(payload, context),
         payload: hook_payload(payload, name, nil),
         metadata: hook_metadata(name)
       )
     ]}
  end

  defp hook_payload(payload, name, state) do
    %{
      hook_event: name,
      state: state,
      tool_name: payload["tool_name"] || payload["toolName"],
      permission_mode: payload["permission_mode"],
      reason: bounded_string(payload["reason"]),
      cwd: payload["cwd"],
      model: payload["model"]
    }
    |> compact()
  end

  defp event_name(payload),
    do: payload["hook_event_name"] || payload["hookEventName"] || payload["type"]

  defp session_id(payload, context) do
    payload["session_id"] || payload["sessionId"] || payload["thread_id"] ||
      payload["threadId"] || payload["thread-id"] || context[:session_id] || context.runtime_id
  end

  defp turn_id(payload, context) do
    payload["turn_id"] || payload["turnId"] || payload["turn-id"] || context[:turn_id]
  end

  defp hook_metadata(name), do: %{hook_event: name}

  defp bounded_string(value) when is_binary(value),
    do: value |> String.trim() |> String.slice(0, 2_000)

  defp bounded_string(_value), do: nil
  defp compact(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
