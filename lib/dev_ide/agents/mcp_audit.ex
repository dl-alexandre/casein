defmodule DevIDE.Agents.MCPAudit do
  @moduledoc """
  Audit + activity helpers for agent MCP tool invocations.
  """

  alias DevIDE.{Agents.Activity, Agents.MCPError, Audit, Labels}
  alias DevIDE.Export.Sanitizer

  @spec record_terminal(String.t(), map(), :ok | {:error, term()}, keyword()) :: :ok
  def record_terminal(tool, args, result, opts \\ []) when is_map(args) do
    workspace_id = terminal_workspace_id(args, opts)
    summary = terminal_summary(tool, args)
    status = if match?({:error, _}, result), do: :error, else: :ok

    _ =
      Activity.record(
        stamp_correlation(%{
          workspace_id: workspace_id,
          source: :terminal_mcp,
          tool: tool,
          summary: summary,
          metadata: terminal_audit_metadata(tool, args),
          status: status
        })
      )

    # Mutating calls persist durably whether they succeeded or failed — a
    # rejected write attempt is audit-worthy. Read-only tools stay memory-only.
    # Rows need a real workspace: the scope-rejection path passes untrusted
    # raw args and may resolve no workspace at all (see terminal_workspace_id).
    if mutating_terminal_tool?(tool) and is_binary(workspace_id) do
      Audit.emit!(
        %{
          workspace_id: workspace_id,
          actor_id: actor_id(args, opts),
          action: "agent.terminal_" <> tool,
          source: "terminal_mcp",
          tool: tool,
          metadata: terminal_audit_metadata(tool, args)
        }
        |> put_error(result)
      )
    end

    _ = Labels.propose_from_mcp(workspace_id, tool, args, result)

    :ok
  end

  @spec record_preview(String.t() | nil, String.t(), map(), term(), keyword()) :: :ok
  def record_preview(workspace_id, tool, args, result, opts \\ [])
      when is_map(args) and is_binary(tool) do
    summary = preview_summary(tool, args)
    status = if match?({:error, _}, result), do: :error, else: :ok
    metadata = preview_audit_metadata(tool, args, result)

    _ =
      Activity.record(
        stamp_correlation(%{
          workspace_id: workspace_id,
          source: :preview_mcp,
          tool: tool,
          summary: summary,
          metadata: metadata,
          status: status
        })
      )

    if mutating_preview_tool?(tool) and is_binary(workspace_id) do
      Audit.emit!(
        %{
          workspace_id: workspace_id,
          actor_id: actor_id(args, opts),
          action: "agent.preview_" <> tool,
          source: "preview_mcp",
          tool: tool,
          metadata: metadata
        }
        |> put_error(result)
      )
    end

    :ok
  end

  # `workspace_id` must come from the caller's *validated* scope (or the
  # endpoint's pre-scoped default) — never from raw tool args, which a caller
  # scoped to workspace A could point at workspace B to forge rows there.
  @spec record_artifact(String.t() | nil, String.t(), map(), term(), keyword()) :: :ok
  def record_artifact(workspace_id, tool, args, result, opts \\ [])
      when is_map(args) and is_binary(tool) do
    summary = artifact_summary(tool, args, result)
    status = if match?({:error, _}, result), do: :error, else: :ok
    metadata = artifact_audit_metadata(tool, args, result)

    _ =
      Activity.record(
        stamp_correlation(%{
          workspace_id: workspace_id,
          source: :artifact_mcp,
          tool: tool,
          summary: summary,
          metadata: metadata,
          status: status
        })
      )

    if mutating_artifact_tool?(tool) and is_binary(workspace_id) do
      Audit.emit!(
        %{
          workspace_id: workspace_id,
          actor_id: actor_id(args, opts),
          action: "agent.artifact_" <> tool,
          source: "artifact_mcp",
          tool: tool,
          metadata: metadata
        }
        |> put_error(result)
      )
    end

    :ok
  end

  defp mutating_terminal_tool?(tool),
    do:
      tool in [
        "terminal_send_keys",
        "terminal_send_command",
        "terminal_send_agent_keys",
        "terminal_send_agent_command",
        "terminal_paste_agent_text",
        "annotation_propose",
        "terminal_set_agent_label",
        "gate_report"
      ]

  defp mutating_preview_tool?(tool),
    do:
      tool in [
        "preview_click",
        "preview_type",
        "preview_press",
        "preview_navigate",
        "preview_open",
        "preview_open_current_workspace",
        "preview_open_here",
        "preview_open_app",
        "preview_open_localhost",
        "preview_close",
        "preview_clear_storage",
        "preview_reload_iframe",
        "devide_reload_page"
      ]

  defp mutating_artifact_tool?(tool),
    do: tool in ["artifact_create", "artifact_update", "artifact_serve", "artifact_snapshot"]

  # Prefer the authenticated actor threaded down from the controller
  # (ws:<workspace_id> / orchestrator:<subject> / global), then an explicit
  # actor_id argument, then the legacy "mcp" fallback.
  defp actor_id(args, opts) do
    case Keyword.get(opts, :actor) do
      actor when is_binary(actor) and actor != "" -> actor
      _ -> actor_id_from_args(args)
    end
  end

  defp actor_id_from_args(args) do
    case Map.get(args, "actor_id") || Map.get(args, :actor_id) do
      id when is_binary(id) and id != "" -> id
      _ -> "mcp"
    end
  end

  # Failed mutating calls persist with a bounded reason atom (the Ecto adapter
  # stores `reason` as a string column); free-text detail rides in metadata,
  # redacted like every other exported string.
  defp put_error(attrs, {:error, reason}) do
    formatted = MCPError.format(reason)

    attrs
    |> Map.put(:reason, error_reason(reason, formatted))
    |> Map.update!(:metadata, &Map.merge(&1, error_metadata(formatted)))
  end

  defp put_error(attrs, _result), do: attrs

  defp error_reason(reason, _formatted) when is_atom(reason) and not is_nil(reason), do: reason
  defp error_reason({reason, _}, _formatted) when is_atom(reason), do: reason
  defp error_reason({reason, _, _}, _formatted) when is_atom(reason), do: reason

  defp error_reason(_reason, %{"error" => error}) when is_binary(error) do
    # Only reuse atoms the runtime already knows — arbitrary error strings must
    # not mint atoms.
    String.to_existing_atom(error)
  rescue
    ArgumentError -> :tool_error
  end

  defp error_reason(_reason, _formatted), do: :tool_error

  defp error_metadata(formatted) do
    %{
      error: preview_result_text(Map.get(formatted, "error")),
      error_message: preview_arg_text(Map.get(formatted, "message"))
    }
    |> compact_metadata()
  end

  # Stamp the in-memory Activity entry with the same correlation_id the durable
  # audit row gets, so the memory tail reconciles with audit_events.
  defp stamp_correlation(attrs), do: DevIDE.Signals.Context.stamp(attrs)

  # Terminal calls resolve their workspace from args — safe on the normal
  # paths because those args are the scope-validated `scope.args`. The
  # scope-rejection path passes raw caller args, so it must override with a
  # trusted `:workspace_id` (the endpoint's authenticated default, possibly
  # nil) instead of letting an attacker-supplied workspace_id attribute rows
  # to a workspace the caller has no scope over.
  defp terminal_workspace_id(args, opts) do
    case Keyword.fetch(opts, :workspace_id) do
      {:ok, trusted} -> trusted
      :error -> workspace_id_from_args(args)
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

  defp terminal_summary("terminal_report_agent_state", args) do
    state = Map.get(args, "state") || Map.get(args, :state)
    message = Map.get(args, "message") || Map.get(args, :message)
    base = if is_binary(state), do: "agent state · " <> state, else: "terminal_report_agent_state"
    if is_binary(message) and message != "", do: base <> " · " <> truncate(message), else: base
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

  defp artifact_summary("artifact_create", args, _result) do
    case arg_value(args, :name) do
      name when is_binary(name) -> "artifact_create · " <> truncate(name)
      _ -> "artifact_create"
    end
  end

  defp artifact_summary(tool, args, result) do
    artifact_id =
      first_present([
        arg_value(args, :artifact_id),
        arg_value(args, :id),
        artifact_result_value(result, :id),
        artifact_result_value(result, :project_id)
      ])

    if is_binary(artifact_id), do: "#{tool_label(tool)} · #{artifact_id}", else: tool_label(tool)
  end

  defp tool_label(tool), do: tool

  # command/keys/text are free text destined for persisted audit rows — redact
  # like the preview/artifact metadata paths, not just truncate.
  defp terminal_audit_metadata(tool, args) do
    %{
      tool: tool,
      session: Map.get(args, "session"),
      pane: Map.get(args, "pane"),
      command: preview_arg_text(Map.get(args, "command")),
      keys: preview_arg_text(Map.get(args, "keys")),
      text: preview_arg_text(Map.get(args, "text"))
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp preview_audit_metadata(tool, args, result) do
    base =
      %{
        tool: tool,
        session_id: arg_value(args, :session_id),
        element_id: arg_value(args, :element_id),
        selector: preview_arg_text(arg_value(args, :selector)),
        text: preview_arg_text(arg_value(args, :text)),
        key: preview_arg_text(arg_value(args, :key)),
        path: preview_result_text(arg_value(args, :path)),
        port: arg_value(args, :port)
      }
      |> compact_metadata()

    Map.merge(base, preview_result_metadata(tool, result))
  end

  defp preview_result_metadata(tool, {:ok, result}) when is_map(result) do
    artifact_url = public_artifact_url(result)

    %{
      tool: tool,
      pane_id: first_present([result_value(result, :pane_id), result_value(result, :pane)]),
      url: preview_result_text(result_value(result, :url)),
      source_url: preview_result_text(result_value(result, :source_url)),
      display_url: preview_result_text(result_value(result, :display_url)),
      preview_title:
        preview_result_text(
          first_present([
            result_value(result, :preview_title),
            result_value(result, :page_title),
            result_value(result, :title)
          ])
        ),
      preview_status:
        preview_result_text(
          first_present([
            result_value(result, :preview_status),
            result_value(result, :browser_status),
            result_value(result, :status)
          ])
        ),
      artifact_url: artifact_url,
      screenshot_url: screenshot_url(tool, result, artifact_url),
      recording_id: preview_result_text(result_value(result, :recording_id)),
      recording_url: recording_url(tool, result, artifact_url),
      recording_status: recording_status(tool, result, artifact_url)
    }
    |> compact_metadata()
  end

  defp preview_result_metadata(_tool, _result), do: %{}

  defp artifact_audit_metadata(tool, args, result) do
    base =
      %{
        tool: tool,
        artifact_id: first_present([arg_value(args, :artifact_id), arg_value(args, :id)]),
        name: preview_arg_text(arg_value(args, :name)),
        kind: arg_value(args, :kind),
        prompt: preview_arg_text(arg_value(args, :prompt))
      }
      |> compact_metadata()

    Map.merge(base, artifact_result_metadata(result))
  end

  defp artifact_result_metadata({:ok, result}) when is_map(result) do
    %{
      artifact_id: artifact_result_value(result, :id),
      project_id: artifact_result_value(result, :project_id),
      runtime_id: artifact_result_value(result, :runtime_id),
      preview_url: preview_result_text(artifact_result_value(result, :preview_url))
    }
    |> compact_metadata()
  end

  defp artifact_result_metadata(_result), do: %{}

  defp artifact_result_value({:ok, result}, key) when is_map(result),
    do: artifact_result_value(result, key)

  defp artifact_result_value(result, key) when is_map(result) do
    Map.get(result, key) || Map.get(result, Atom.to_string(key))
  end

  defp artifact_result_value(_result, _key), do: nil

  defp screenshot_url("preview_screenshot", _result, artifact_url), do: artifact_url

  defp screenshot_url(_tool, result, _artifact_url),
    do: public_artifact_url(result_value(result, :screenshot_url))

  defp recording_url(tool, result, artifact_url) do
    first_present([
      public_artifact_url(result_value(result, :recording_url)),
      public_artifact_url(result_value(result, :playback_url)),
      if(tool == "preview_record_stop", do: artifact_url, else: nil)
    ])
  end

  defp recording_status(tool, result, artifact_url) do
    first_present([
      preview_result_text(result_value(result, :recording_status)),
      preview_result_text(result_value(result, :status)),
      if(tool == "preview_record_stop" and is_binary(artifact_url), do: "recorded", else: nil)
    ])
  end

  defp public_artifact_url(result) when is_map(result) do
    [
      result_value(result, :artifact_url),
      result_value(result, :screenshot_url),
      result_value(result, :recording_url),
      result_value(result, :artifact_path),
      result_value(result, :url),
      result_value(result, :display_url)
    ]
    |> Enum.map(&public_artifact_url/1)
    |> first_present()
  end

  defp public_artifact_url(value) do
    with url when is_binary(url) <- preview_result_text(value),
         %URI{path: "/preview-artifacts/" <> _rest} <- URI.parse(url) do
      url
    else
      _ -> nil
    end
  end

  defp arg_value(map, key), do: map_value(map, key)
  defp result_value(map, key), do: map_value(map, key)

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, string_key) -> Map.get(map, string_key)
      true -> nil
    end
  end

  defp preview_arg_text(nil), do: nil
  defp preview_arg_text(value), do: value |> preview_result_text() |> truncate()

  defp preview_result_text(nil), do: nil

  defp preview_result_text(value) when is_binary(value) do
    Sanitizer.redact_text(value)
  end

  defp preview_result_text(value)
       when is_atom(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: value |> to_string() |> preview_result_text()

  defp preview_result_text(_value), do: nil

  defp first_present(values) when is_list(values) do
    Enum.find(values, &present?/1)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp compact_metadata(map) do
    map
    |> Enum.reject(fn {_k, v} -> not present?(v) end)
    |> Map.new()
  end

  defp session_part(args), do: maybe_kv("session", Map.get(args, "session"))
  defp pane_part(args), do: maybe_kv("pane", Map.get(args, "pane"))
  defp lines_part(args), do: maybe_kv("lines", Map.get(args, "lines"))

  defp command_part(tool, args)
       when tool in ["terminal_send_command", "terminal_send_agent_command"],
       do: maybe_kv("cmd", truncate(Map.get(args, "command")))

  defp command_part(tool, args) when tool in ["terminal_send_keys", "terminal_send_agent_keys"],
    do: maybe_kv("keys", truncate(Map.get(args, "keys")))

  defp command_part("terminal_paste_agent_text", args),
    do: maybe_kv("text", truncate(Map.get(args, "text")))

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
