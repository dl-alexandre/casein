defmodule Casein.Agents.AgentEvents do
  @moduledoc """
  Durable, append-only projection for normalized agent session events.

  Source identity is `{workspace_id, stream_id, source_event_id}` so ACP replay
  and transcript recovery can meet in one stream without duplicating events.
  Payloads are metadata-only unless a constructor explicitly marks deliberate
  operator-authored content.
  """

  alias Casein.Agents.AgentEvent
  alias Casein.Signals.{Context, Publish}

  require Logger

  @max_payload_bytes 32 * 1024
  @default_limit 100

  @type append_result ::
          {:ok, AgentEvent.t(), :inserted | :duplicate} | {:error, term()}

  @spec append(map()) :: append_result()
  def append(attrs) when is_map(attrs) do
    attrs = attrs |> stamp_context() |> normalize_attrs()

    case safe_record(attrs) do
      {:ok, %AgentEvent{} = event, :inserted} = result ->
        Publish.agent_event(event)
        Context.advance(event.id)
        result

      {:ok, %AgentEvent{}, :duplicate} = result ->
        result

      {:error, _reason} = error ->
        error
    end
  end

  @doc "Record a metadata-only MCP completion. Command, keys, text, and results are excluded."
  @spec append_mcp(String.t(), String.t(), map(), :ok | :error) :: append_result()
  def append_mcp(workspace_id, ingress, attrs, status)
      when is_binary(workspace_id) and is_binary(ingress) and is_map(attrs) do
    source_event_id = map_value(attrs, :source_event_id) || Ecto.UUID.generate()
    tmux_session_id = map_value(attrs, :tmux_session_id) || map_value(attrs, :session)
    pane_id = map_value(attrs, :pane_id) || map_value(attrs, :pane)
    agent_session_id = map_value(attrs, :agent_session_id)
    tool = map_value(attrs, :tool) || "unknown"

    append(%{
      workspace_id: workspace_id,
      stream_id: stream_id("mcp", agent_session_id, tmux_session_id, pane_id, workspace_id),
      producer: "devide",
      ingress: ingress,
      source_event_id: source_event_id,
      event_type: "mcp.completed",
      agent_session_id: agent_session_id,
      tmux_session_id: tmux_session_id,
      pane_id: pane_id,
      actor_id: map_value(attrs, :actor_id),
      status: status,
      summary: "MCP · #{tool} · #{status}",
      payload: compact(%{"schema_version" => 1, "tool" => tool})
    })
  end

  @doc "Record a metadata-only structured runtime event such as ACP tool, plan, or permission data."
  @spec append_runtime(map()) :: append_result()
  def append_runtime(attrs) when is_map(attrs) do
    producer = normalize_label(map_value(attrs, :producer)) || "unknown"
    ingress = normalize_label(map_value(attrs, :ingress)) || "runtime"
    agent_session_id = optional_string(map_value(attrs, :agent_session_id))

    append(%{
      workspace_id: map_value(attrs, :workspace_id),
      stream_id:
        map_value(attrs, :stream_id) ||
          stream_id(producer, agent_session_id, nil, nil, map_value(attrs, :workspace_id)),
      producer: producer,
      ingress: ingress,
      source_event_id: map_value(attrs, :source_event_id),
      source_sequence: map_value(attrs, :source_sequence),
      event_type: map_value(attrs, :event_type),
      agent_session_id: agent_session_id,
      tmux_session_id: map_value(attrs, :tmux_session_id),
      pane_id: map_value(attrs, :pane_id),
      status: map_value(attrs, :status),
      summary: map_value(attrs, :summary),
      payload: map_value(attrs, :payload) || %{},
      occurred_at: map_value(attrs, :occurred_at)
    })
  end

  @doc "Record one real semantic-state transition, excluding the free-form state message."
  @spec append_state_transition(map()) :: append_result()
  def append_state_transition(attrs) when is_map(attrs) do
    workspace_id = map_value(attrs, :workspace_id)
    tmux_session_id = map_value(attrs, :tmux_session_id)
    pane_id = map_value(attrs, :pane_id)
    state = normalize_label(map_value(attrs, :state))
    prior_state = normalize_label(map_value(attrs, :prior_state))

    append(%{
      workspace_id: workspace_id,
      stream_id: stream_id("tmux", nil, tmux_session_id, pane_id, workspace_id),
      producer: normalize_label(map_value(attrs, :producer)) || "agent",
      ingress: normalize_label(map_value(attrs, :ingress)) || "agent_state",
      source_event_id: map_value(attrs, :source_event_id) || Ecto.UUID.generate(),
      event_type: "agent.state_changed",
      agent_session_id: map_value(attrs, :agent_session_id),
      tmux_session_id: tmux_session_id,
      pane_id: pane_id,
      status: state,
      summary: "Agent state · #{state || "unknown"}",
      payload:
        compact(%{
          "schema_version" => 1,
          "state" => state,
          "prior_state" => prior_state,
          "source" => normalize_label(map_value(attrs, :source)),
          "tool" => optional_string(map_value(attrs, :tool)),
          "message_present" => present?(map_value(attrs, :message))
        })
    })
  end

  @doc "Record a changed worktree exit handoff after its runtime record is durable."
  @spec append_handoff(map()) :: append_result()
  def append_handoff(attrs) when is_map(attrs) do
    workspace_id = map_value(attrs, :workspace_id)
    runtime_id = map_value(attrs, :runtime_id)
    reported_at = map_value(attrs, :reported_at)

    append(%{
      workspace_id: workspace_id,
      stream_id: "runtime:#{runtime_id}",
      producer: normalize_label(map_value(attrs, :producer)) || "agent",
      ingress: normalize_label(map_value(attrs, :ingress)) || "worktree_report",
      source_event_id:
        map_value(attrs, :source_event_id) || "handoff:#{runtime_id}:#{reported_at}",
      event_type: "worktree.handoff",
      privacy_class: "operator_content",
      agent_session_id: map_value(attrs, :agent_session_id),
      tmux_session_id: map_value(attrs, :tmux_session_id),
      runtime_id: runtime_id,
      actor_id: map_value(attrs, :actor_id),
      status: map_value(attrs, :exit_status),
      summary: "Worktree handoff · #{map_value(attrs, :exit_status) || "reported"}",
      payload:
        compact(%{
          "schema_version" => 1,
          "branch" => map_value(attrs, :branch),
          "exit_status" => map_value(attrs, :exit_status),
          "handoff" => truncate_operator_content(map_value(attrs, :handoff))
        }),
      occurred_at: reported_at
    })
  end

  @doc "Record normalized transcript identities without persisting transcript text or tool input."
  @spec append_transcript_entries(String.t(), map(), [map()]) :: [append_result()]
  def append_transcript_entries(workspace_id, context, entries)
      when is_binary(workspace_id) and is_map(context) and is_list(entries) do
    agent_session_id = map_value(context, :agent_session_id)
    producer = normalize_label(map_value(context, :producer)) || "unknown"

    Enum.map(entries, fn entry ->
      role = normalize_label(map_value(entry, :role)) || "unknown"
      cursor = map_value(entry, :cursor)
      tools = map_value(entry, :tool_calls) || []
      tool_names = Enum.map(tools, &map_value(&1, :name)) |> Enum.filter(&is_binary/1)

      append(%{
        workspace_id: workspace_id,
        stream_id: stream_id(producer, agent_session_id, nil, nil, workspace_id),
        producer: producer,
        ingress: "transcript",
        source_event_id: cursor,
        event_type: "transcript.#{role}_message",
        agent_session_id: agent_session_id,
        tmux_session_id: map_value(context, :tmux_session_id),
        pane_id: map_value(context, :pane_id),
        summary: "Transcript · #{role}",
        payload:
          compact(%{
            "schema_version" => 1,
            "role" => role,
            "cursor" => cursor,
            "text_present" => present?(map_value(entry, :text)),
            "tool_names" => tool_names,
            "timestamp" => map_value(entry, :timestamp)
          }),
        occurred_at: map_value(entry, :timestamp)
      })
    end)
  end

  @spec recent_for(String.t(), keyword()) :: [AgentEvent.t()]
  def recent_for(workspace_id, opts \\ []) when is_binary(workspace_id) do
    impl().recent_for(workspace_id, normalize_query_opts(opts))
  end

  @doc "Replay events in durable insertion order after an opaque cursor."
  @spec replay(String.t(), keyword()) :: %{events: [AgentEvent.t()], cursor: String.t() | nil}
  def replay(workspace_id, opts \\ []) when is_binary(workspace_id) do
    {after_at, after_id} = decode_cursor(Keyword.get(opts, :after))
    events = impl().replay(workspace_id, after_at, after_id, normalize_query_opts(opts))
    %{events: events, cursor: cursor_for(List.last(events)) || Keyword.get(opts, :after)}
  end

  @doc "Build the opaque replay cursor for a stored event."
  @spec cursor_for(AgentEvent.t() | nil) :: String.t() | nil
  def cursor_for(nil), do: nil

  def cursor_for(%AgentEvent{} = event) do
    [DateTime.to_iso8601(event.inserted_at), event.id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @spec list_for_session(String.t(), String.t(), keyword()) :: [AgentEvent.t()]
  def list_for_session(workspace_id, agent_session_id, opts \\ [])
      when is_binary(workspace_id) and is_binary(agent_session_id) do
    impl().list_for_session(workspace_id, agent_session_id, normalize_query_opts(opts))
  end

  @spec list_by_correlation(String.t(), keyword()) :: [AgentEvent.t()]
  def list_by_correlation(correlation_id, opts \\ []) when is_binary(correlation_id) do
    impl().list_by_correlation(correlation_id, normalize_query_opts(opts))
  end

  @doc false
  def clear, do: impl().clear()

  defp stamp_context(attrs) do
    stamped = Context.stamp(%{metadata: map_value(attrs, :payload) || %{}})
    Map.put(attrs, :payload, stamped.metadata)
  end

  defp normalize_attrs(attrs) do
    now = DateTime.utc_now()
    payload = normalize_payload(map_value(attrs, :payload))

    %{
      id: optional_string(map_value(attrs, :id)),
      workspace_id: optional_string(map_value(attrs, :workspace_id)),
      stream_id: optional_string(map_value(attrs, :stream_id)),
      producer: normalize_label(map_value(attrs, :producer)),
      ingress: normalize_label(map_value(attrs, :ingress)),
      source_event_id: optional_string(map_value(attrs, :source_event_id)),
      source_sequence: normalize_sequence(map_value(attrs, :source_sequence)),
      event_type: optional_string(map_value(attrs, :event_type)),
      privacy_class: normalize_label(map_value(attrs, :privacy_class)) || "metadata",
      agent_session_id: optional_string(map_value(attrs, :agent_session_id)),
      tmux_session_id: optional_string(map_value(attrs, :tmux_session_id)),
      pane_id: optional_string(map_value(attrs, :pane_id)),
      runtime_id: optional_string(map_value(attrs, :runtime_id)),
      actor_id: optional_string(map_value(attrs, :actor_id)),
      status: normalize_label(map_value(attrs, :status)),
      summary: normalize_summary(map_value(attrs, :summary)),
      correlation_id:
        optional_string(map_value(attrs, :correlation_id) || Map.get(payload, "correlation_id")),
      causation_id:
        optional_string(map_value(attrs, :causation_id) || Map.get(payload, "causation_id")),
      payload: payload,
      occurred_at: normalize_datetime(map_value(attrs, :occurred_at), now),
      inserted_at: normalize_datetime(map_value(attrs, :inserted_at), now)
    }
  end

  defp normalize_payload(nil), do: %{}

  defp normalize_payload(payload) when is_map(payload) do
    encoded = Jason.encode!(payload)

    if byte_size(encoded) > @max_payload_bytes do
      encoded
      |> Jason.decode!()
      |> Map.take([
        "schema_version",
        "correlation_id",
        "causation_id",
        "session_id",
        "agent_session_id"
      ])
      |> Map.put("truncated", true)
    else
      Jason.decode!(encoded)
    end
  rescue
    _ -> %{}
  end

  defp normalize_payload(_payload), do: %{}

  defp stream_id(producer, agent_session_id, _tmux, _pane, _workspace)
       when is_binary(agent_session_id) and agent_session_id != "",
       do: "#{producer}:#{agent_session_id}"

  defp stream_id(_producer, _agent_session_id, tmux, pane, _workspace)
       when is_binary(tmux) and is_binary(pane),
       do: "tmux:#{tmux}:#{pane}"

  defp stream_id(_producer, _agent_session_id, tmux, _pane, _workspace)
       when is_binary(tmux),
       do: "tmux:#{tmux}"

  defp stream_id(producer, _agent_session_id, _tmux, _pane, workspace),
    do: "#{producer}:workspace:#{workspace}"

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp compact(map),
    do: map |> Enum.reject(fn {_key, value} -> value in [nil, ""] end) |> Map.new()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp normalize_label(nil), do: nil
  defp normalize_label(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_label(value) when is_binary(value), do: optional_string(value)
  defp normalize_label(value), do: value |> to_string() |> optional_string()

  defp normalize_summary(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp normalize_summary(_value), do: ""

  defp truncate_operator_content(value) when is_binary(value), do: String.slice(value, 0, 2_000)
  defp truncate_operator_content(_value), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp normalize_sequence(value) when is_integer(value) and value >= 0, do: value
  defp normalize_sequence(_value), do: nil

  defp normalize_datetime(%DateTime{} = value, _default), do: value

  defp normalize_datetime(value, default) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> default
    end
  end

  defp normalize_datetime(_value, default), do: default

  defp normalize_query_opts(opts) do
    [limit: opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()]
  end

  defp decode_cursor(nil), do: {nil, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [inserted_at, id]} when is_binary(id) <- Jason.decode(json),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(inserted_at) do
      {datetime, id}
    else
      _ -> {nil, nil}
    end
  end

  defp decode_cursor(_cursor), do: {nil, nil}

  defp clamp_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(1_000)
  defp clamp_limit(_limit), do: @default_limit

  defp safe_record(attrs) do
    impl().record(attrs)
  rescue
    exception ->
      Logger.warning("agent event append failed (#{inspect(exception.__struct__)})")
      {:error, :adapter_failure}
  catch
    :exit, _reason ->
      Logger.warning("agent event append exited")
      {:error, :adapter_failure}
  end

  defp impl do
    Application.get_env(:casein, :agent_events_adapter, Casein.Agents.AgentEvents.EctoAdapter)
  end
end
