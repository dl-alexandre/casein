defmodule Casein.AgentSessions.GrokACP.Protocol do
  @moduledoc false

  @max_line_bytes 8 * 1024 * 1024

  def request(id, method, params) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, method: method, params: params}) <> "\n"
  end

  def result(id, result) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, result: result}) <> "\n"
  end

  def error(id, code, message) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}) <> "\n"
  end

  @doc "Decodes arbitrary stdout chunks into newline-delimited JSON-RPC messages."
  def feed(buffer, data) when is_binary(buffer) and is_binary(data) do
    combined = buffer <> data
    parts = String.split(combined, "\n")
    remainder = List.last(parts) || ""
    complete = Enum.drop(parts, -1)

    cond do
      byte_size(remainder) > @max_line_bytes ->
        {[{:error, :line_too_large}], ""}

      true ->
        decoded =
          complete
          |> Enum.map(&String.trim_trailing(&1, "\r"))
          |> Enum.reject(&(&1 == ""))
          |> Enum.map(&decode/1)

        {decoded, remainder}
    end
  end

  def classify(%{"id" => id, "method" => "session/request_permission", "params" => params}) do
    {:permission_request, id, params}
  end

  def classify(%{"method" => method} = message)
      when method in ["session/update", "x.ai/session/update"] do
    classify_session_update(Map.get(message, "params", %{}))
  end

  def classify(%{"method" => "_x.ai/session/update", "params" => outer}) do
    classify_session_update(Map.get(outer, "params", %{}))
  end

  def classify(%{"method" => method} = message)
      when method in ["x.ai/session_notification", "_x.ai/session_notification"] do
    params = inner_params(message)

    case get_in(params, ["update", "sessionUpdate"]) do
      "interaction_resolved" ->
        update = Map.get(params, "update", %{})

        {:interaction_resolved, Map.get(update, "toolCallId") || Map.get(update, "tool_call_id")}

      _ ->
        :ignore
    end
  end

  def classify(%{"id" => id, "result" => result}), do: {:response, id, {:ok, result}}
  def classify(%{"id" => id, "error" => error}), do: {:response, id, {:error, error}}

  def classify(%{"id" => id, "method" => method, "params" => params}),
    do: {:unsupported_request, id, method, params}

  def classify(_message), do: :ignore

  def activity_attrs(workspace_id, {:tool_call, update}, session_id) do
    status = Map.get(update, "status") || "pending"
    title = present(Map.get(update, "title") || Map.get(update, "kind") || "Tool call")

    %{
      workspace_id: workspace_id,
      source: :grok_acp,
      tool: "grok_tool_call",
      summary: truncate("#{title} · #{status}"),
      status: activity_status(status),
      metadata: %{
        event: "tool_call",
        session_id: session_id,
        tool_call_id: tool_call_id(update),
        kind: present(Map.get(update, "kind")),
        status: present(status)
      }
    }
  end

  def activity_attrs(workspace_id, {:tool_call_update, update}, session_id) do
    status = Map.get(update, "status") || "updated"
    title = present(Map.get(update, "title") || Map.get(update, "kind") || "Tool call")

    %{
      workspace_id: workspace_id,
      source: :grok_acp,
      tool: "grok_tool_call",
      summary: truncate("#{title} · #{status}"),
      status: activity_status(status),
      metadata: %{
        event: "tool_call_update",
        session_id: session_id,
        tool_call_id: tool_call_id(update),
        kind: present(Map.get(update, "kind")),
        status: present(status)
      }
    }
  end

  def activity_attrs(workspace_id, {:plan, update}, session_id) do
    entries = Map.get(update, "entries", [])
    count = if is_list(entries), do: length(entries), else: 0

    %{
      workspace_id: workspace_id,
      source: :grok_acp,
      tool: "grok_plan",
      summary: "Plan updated · #{count} #{if count == 1, do: "step", else: "steps"}",
      status: :ok,
      metadata: %{
        event: "plan",
        session_id: session_id,
        step_count: count,
        status_counts: plan_status_counts(entries)
      }
    }
  end

  def activity_attrs(workspace_id, {:permission_request, request_id, params}, session_id) do
    tool_call = Map.get(params, "toolCall", %{})
    title = present(Map.get(tool_call, "title") || Map.get(tool_call, "kind") || "Tool call")
    options = Map.get(params, "options", [])

    %{
      workspace_id: workspace_id,
      source: :grok_acp,
      tool: "grok_permission_request",
      summary: truncate("Permission requested · #{title}"),
      status: :ok,
      metadata: %{
        event: "permission_request",
        status: "attention",
        session_id: Map.get(params, "sessionId") || session_id,
        request_id: to_string(request_id),
        tool_call_id: tool_call_id(tool_call),
        option_count: if(is_list(options), do: length(options), else: 0)
      }
    }
  end

  def permission_summary(request_id, params) do
    tool_call = Map.get(params, "toolCall", %{})
    options = Map.get(params, "options", [])

    %{
      request_id: request_id,
      session_id: Map.get(params, "sessionId"),
      tool_call_id: tool_call_id(tool_call),
      title: truncate(present(Map.get(tool_call, "title") || "Tool call")),
      options: permission_options(options)
    }
  end

  defp classify_session_update(params) do
    update = Map.get(params, "update", %{})

    identity = %{
      session_id: Map.get(params, "sessionId"),
      source_event_id: source_event_id(params, update),
      source_sequence: source_sequence(params, update)
    }

    case Map.get(update, "sessionUpdate") do
      "tool_call" -> {:activity, {:tool_call, update}, identity}
      "tool_call_update" -> {:activity, {:tool_call_update, update}, identity}
      "plan" -> {:activity, {:plan, update}, identity}
      _ -> :ignore
    end
  end

  defp source_event_id(params, update) do
    Map.get(params, "eventId") ||
      get_in(params, ["_meta", "eventId"]) ||
      Map.get(update, "eventId") ||
      get_in(update, ["_meta", "eventId"]) ||
      derived_event_id(params, update)
  end

  defp source_sequence(params, update) do
    [
      Map.get(params, "sequence"),
      get_in(params, ["_meta", "sequence"]),
      get_in(params, ["_meta", "updateIndex"]),
      Map.get(update, "sequence"),
      get_in(update, ["_meta", "sequence"]),
      get_in(update, ["_meta", "updateIndex"])
    ]
    |> Enum.find(&is_integer/1)
  end

  defp derived_event_id(params, update) do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({Map.get(params, "sessionId"), update}))
      |> Base.encode16(case: :lower)

    "derived:" <> digest
  end

  defp inner_params(%{"method" => "_" <> _, "params" => outer}) do
    Map.get(outer, "params", outer)
  end

  defp inner_params(message), do: Map.get(message, "params", %{})

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, message} when is_map(message) -> {:ok, message}
      {:ok, _other} -> {:error, :non_object_message}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp permission_options(options) when is_list(options) do
    Enum.map(options, fn option ->
      %{
        option_id: Map.get(option, "optionId"),
        name: truncate(present(Map.get(option, "name"))),
        kind: present(Map.get(option, "kind"))
      }
    end)
  end

  defp permission_options(_), do: []

  defp plan_status_counts(entries) when is_list(entries) do
    Enum.reduce(entries, %{}, fn entry, counts ->
      status = present(Map.get(entry, "status") || "unknown")
      Map.update(counts, status, 1, &(&1 + 1))
    end)
  end

  defp plan_status_counts(_), do: %{}

  defp activity_status(status) when status in ["failed", "error"], do: :error
  defp activity_status(_status), do: :ok

  defp tool_call_id(map) do
    Map.get(map, "toolCallId") || Map.get(map, "tool_call_id") || Map.get(map, "id")
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(value) when is_atom(value), do: Atom.to_string(value)
  defp present(_value), do: "unknown"

  defp truncate(value) when is_binary(value) do
    if String.length(value) > 160, do: String.slice(value, 0, 157) <> "…", else: value
  end
end
