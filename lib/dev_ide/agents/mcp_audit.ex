defmodule DevIDE.Agents.MCPAudit do
  @moduledoc """
  Audit + activity helpers for agent MCP tool invocations.
  """

  alias DevIDE.{Agents.Activity, Audit, Labels}

  @spec record_terminal(String.t(), map(), :ok | {:error, term()}) :: :ok
  def record_terminal(tool, args, result) when is_map(args) do
    workspace_id = workspace_id_from_args(args)
    summary = terminal_summary(tool, args)
    status = if match?({:error, _}, result), do: :error, else: :ok

    _ =
      Activity.record(%{
        workspace_id: workspace_id,
        source: :terminal_mcp,
        tool: tool,
        summary: summary,
        metadata: terminal_audit_metadata(tool, args),
        status: status
      })

    if mutating_terminal_tool?(tool) and status == :ok do
      Audit.emit!(%{
        workspace_id: workspace_id,
        actor_id: actor_id(args),
        action: "agent.terminal_" <> tool,
        metadata: terminal_audit_metadata(tool, args)
      })
    end

    _ = Labels.propose_from_mcp(workspace_id, tool, args, result)

    :ok
  end

  @spec record_preview(String.t() | nil, String.t(), map(), :ok | {:error, term()}) :: :ok
  def record_preview(workspace_id, tool, args, result) when is_map(args) and is_binary(tool) do
    summary = preview_summary(tool, args)
    status = if match?({:error, _}, result), do: :error, else: :ok

    _ =
      Activity.record(%{
        workspace_id: workspace_id,
        source: :preview_mcp,
        tool: tool,
        summary: summary,
        metadata: preview_audit_metadata(tool, args),
        status: status
      })

    if mutating_preview_tool?(tool) and status == :ok and is_binary(workspace_id) do
      Audit.emit!(%{
        workspace_id: workspace_id,
        actor_id: actor_id(args),
        action: "agent.preview_" <> tool,
        metadata: preview_audit_metadata(tool, args)
      })
    end

    :ok
  end

  defp mutating_terminal_tool?(tool),
    do:
      tool in [
        "terminal_send_keys",
        "terminal_send_command",
        "annotation_propose",
        "terminal_set_agent_label"
      ]

  defp mutating_preview_tool?(tool),
    do:
      tool in [
        "preview_click",
        "preview_type",
        "preview_press",
        "preview_navigate",
        "preview_open_app",
        "preview_open_localhost"
      ]

  defp actor_id(args) do
    case Map.get(args, "actor_id") || Map.get(args, :actor_id) do
      id when is_binary(id) and id != "" -> id
      _ -> "mcp"
    end
  end

  defp workspace_id_from_args(args) do
    Map.get(args, "workspace_id") || Map.get(args, :workspace_id)
  end

  defp terminal_summary("annotation_propose", args) do
    author = Map.get(args, "author_type") || Map.get(args, :author_type)
    path = Map.get(args, "file_path") || Map.get(args, :file_path)
    parts = Enum.reject([author && "author=#{author}", path && "file=#{path}"], &is_nil/1)

    if parts == [],
      do: "annotation_propose",
      else: "annotation_propose · " <> Enum.join(parts, " ")
  end

  defp terminal_summary("terminal_set_agent_label", args) do
    label = Map.get(args, "label") || Map.get(args, :label)
    if is_binary(label), do: "set label · " <> truncate(label), else: "terminal_set_agent_label"
  end

  defp terminal_summary("annotation_list", args) do
    state = Map.get(args, "approval_state") || Map.get(args, :approval_state)
    if is_binary(state), do: "annotation_list · #{state}", else: "annotation_list"
  end

  defp terminal_summary(tool, args) do
    parts =
      [
        session_part(args),
        pane_part(args),
        command_part(tool, args),
        lines_part(args)
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: tool, else: Enum.join(parts, " · ")
  end

  defp preview_summary("preview_open_localhost", args) do
    port = Map.get(args, "port") || Map.get(args, :port)
    path = Map.get(args, "path") || Map.get(args, :path) || "/"
    "#{tool_label("preview_open_localhost")} · :#{port}#{path}"
  end

  defp preview_summary("preview_navigate", args) do
    session = Map.get(args, "session_id") || Map.get(args, :session_id)
    path = Map.get(args, "path") || Map.get(args, :path)
    parts = Enum.reject([session && "session #{session}", path && "→ #{path}"], &is_nil/1)
    if parts == [], do: "preview_navigate", else: "preview_navigate · " <> Enum.join(parts, " ")
  end

  defp preview_summary(tool, args) do
    case Map.get(args, "session_id") || Map.get(args, :session_id) do
      id when is_integer(id) -> "#{tool_label(tool)} · session #{id}"
      id when is_binary(id) -> "#{tool_label(tool)} · session #{id}"
      _ -> tool_label(tool)
    end
  end

  defp tool_label(tool), do: tool

  defp terminal_audit_metadata(tool, args) do
    %{
      tool: tool,
      session: Map.get(args, "session"),
      pane: Map.get(args, "pane"),
      command: truncate(Map.get(args, "command")),
      keys: truncate(Map.get(args, "keys"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp preview_audit_metadata(tool, args) do
    %{
      tool: tool,
      session_id: Map.get(args, "session_id"),
      selector: Map.get(args, "selector"),
      key: Map.get(args, "key"),
      path: Map.get(args, "path"),
      port: Map.get(args, "port")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp session_part(args), do: maybe_kv("session", Map.get(args, "session"))
  defp pane_part(args), do: maybe_kv("pane", Map.get(args, "pane"))
  defp lines_part(args), do: maybe_kv("lines", Map.get(args, "lines"))

  defp command_part("terminal_send_command", args),
    do: maybe_kv("cmd", truncate(Map.get(args, "command")))

  defp command_part("terminal_send_keys", args),
    do: maybe_kv("keys", truncate(Map.get(args, "keys")))

  defp command_part(_, _), do: nil

  defp maybe_kv(_key, nil), do: nil
  defp maybe_kv(_key, ""), do: nil
  defp maybe_kv(key, value), do: "#{key}=#{value}"

  defp truncate(nil), do: nil

  defp truncate(value) when is_binary(value) do
    if String.length(value) > 120, do: String.slice(value, 0, 117) <> "...", else: value
  end

  defp truncate(value), do: to_string(value)
end
