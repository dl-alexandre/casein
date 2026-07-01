defmodule DevIDE.PreviousSessions do
  @moduledoc """
  Read-only search over recent session context.

  This module intentionally composes existing sources instead of introducing a
  new store: live session-directory rows, recent audit events, recent MCP
  activity, and ephemeral pane labels. Callers can wire this to a debounced UI
  without putting search concerns into the terminal control plane.
  """

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Labels
  alias DevIDE.Terminals.SessionDirectory

  @default_limit 20
  @max_limit 50
  @source_limit 200

  @type source :: :session | :audit | :activity | :label
  @type source_filter :: source() | :preview

  @type result :: %{
          id: String.t(),
          source: source(),
          workspace_id: String.t() | nil,
          session: String.t() | nil,
          pane: String.t() | nil,
          title: String.t(),
          summary: String.t(),
          status: String.t() | nil,
          href: String.t() | nil,
          occurred_at: DateTime.t() | nil,
          preview: map() | nil,
          metadata: map(),
          matched_fields: [String.t()],
          score: non_neg_integer()
        }

  @doc "Default number of results returned by `search/2`."
  def default_limit, do: @default_limit

  @doc "Hard cap for user-provided result limits."
  def max_limit, do: @max_limit

  @doc "Default number of audit/activity rows fetched before local filtering."
  def source_limit, do: @source_limit

  @spec search(String.t(), keyword()) :: %{
          workspace_id: String.t(),
          query: String.t(),
          workspace: String.t() | nil,
          limit: pos_integer(),
          results: [result()]
        }
  def search(workspace_id, opts \\ []) when is_binary(workspace_id) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))
    source_limit = normalize_source_limit(opts, limit)
    query = normalize_query(Keyword.get(opts, :query, ""))

    filters = %{
      query: String.downcase(query),
      workspace:
        normalize_query(Keyword.get(opts, :workspace) || Keyword.get(opts, :workspace_filter)),
      workspace_aliases: normalize_workspace_aliases(workspace_id, opts),
      source: normalize_source_filter(Keyword.get(opts, :source) || Keyword.get(opts, :sources)),
      session: normalize_query(Keyword.get(opts, :session) || Keyword.get(opts, :session_id)),
      pane: normalize_query(Keyword.get(opts, :pane) || Keyword.get(opts, :pane_id)),
      since: datetime_option(opts, [:since, :from], :start),
      until: datetime_option(opts, [:until, :to], :end)
    }

    sessions = read_sessions(workspace_id, opts)
    audit_events = read_audit_events(workspace_id, source_limit, opts)
    activity_entries = read_activity_entries(workspace_id, source_limit, opts)

    labels_by_session =
      [sessions, audit_events, activity_entries]
      |> candidate_session_ids()
      |> read_labels(opts)

    results =
      workspace_id
      |> candidates(sessions, audit_events, activity_entries, labels_by_session)
      |> Enum.map(&rank_candidate(&1, filters))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&sort_key/1)
      |> Enum.take(limit)
      |> Enum.map(&public_result/1)

    %{
      workspace_id: workspace_id,
      query: query,
      workspace: optional_filter_value(filters.workspace),
      source: source_filter_value(filters.source),
      limit: limit,
      results: results
    }
  end

  defp candidates(workspace_id, sessions, audit_events, activity_entries, labels_by_session) do
    session_candidates(workspace_id, sessions) ++
      audit_candidates(workspace_id, audit_events) ++
      activity_candidates(workspace_id, activity_entries) ++
      label_candidates(workspace_id, labels_by_session)
  end

  defp session_candidates(workspace_id, sessions) do
    Enum.map(sessions, fn session ->
      metadata = metadata(session)
      session_id = session_identifier(session, metadata)

      title =
        first_string([metadata_get(metadata, :session_alias), field(session, :sid), session_id])

      summary = session_summary(session, metadata)

      candidate(
        source: :session,
        id: candidate_id("session", first_string([field(session, :id), session_id])),
        workspace_id: first_string([field(session, :workspace_id), workspace_id]),
        session: session_id,
        pane: nil,
        title: title || "Terminal session",
        summary: summary,
        status: status_string(field(session, :status)),
        occurred_at: metadata_time(metadata),
        metadata: metadata,
        identifiers:
          strings([
            field(session, :id),
            field(session, :sid),
            field(session, :runner_id),
            session_id,
            metadata_get(metadata, :runtime_id),
            metadata_get(metadata, :session_alias)
          ])
      )
    end)
  end

  defp audit_candidates(workspace_id, events) do
    Enum.map(events, fn event ->
      metadata = metadata(event)
      action = field(event, :action)
      target_ref = field(event, :target_ref)
      tool = metadata_get(metadata, :tool)
      session = audit_session(event, metadata)
      pane = first_string([metadata_get(metadata, :pane), metadata_get(metadata, :pane_id)])

      candidate(
        source: :audit,
        id: candidate_id("audit", field(event, :id)),
        workspace_id: first_string([field(event, :workspace_id), workspace_id]),
        session: session,
        pane: pane,
        title:
          first_string([
            metadata_get(metadata, :title),
            metadata_get(metadata, :prompt_excerpt),
            metadata_get(metadata, :command),
            metadata_get(metadata, :text),
            action
          ]),
        summary: audit_summary(event),
        status: first_string([metadata_get(metadata, :status), action_status(action)]),
        occurred_at: field(event, :inserted_at),
        preview: preview_context(:audit, action, tool, metadata),
        metadata: metadata,
        identifiers:
          strings([
            target_ref,
            session,
            pane,
            metadata_get(metadata, :session_id),
            metadata_get(metadata, :url),
            metadata_get(metadata, :display_url),
            metadata_get(metadata, :screenshot_url),
            metadata_get(metadata, :artifact_url),
            metadata_get(metadata, :run_id),
            metadata_get(metadata, :command_id),
            tool
          ])
      )
    end)
  end

  defp activity_candidates(workspace_id, entries) do
    Enum.map(entries, fn entry ->
      metadata = metadata(entry)
      session = activity_session(metadata)
      pane = first_string([metadata_get(metadata, :pane), metadata_get(metadata, :pane_id)])
      tool = field(entry, :tool)
      summary = field(entry, :summary) || ""

      candidate(
        source: :activity,
        id: candidate_id("activity", field(entry, :id)),
        workspace_id: first_string([field(entry, :workspace_id), workspace_id]),
        session: session,
        pane: pane,
        title:
          first_string([
            metadata_get(metadata, :title),
            metadata_get(metadata, :prompt_excerpt),
            metadata_get(metadata, :command),
            metadata_get(metadata, :text),
            summary,
            tool
          ]),
        summary: summary,
        status:
          first_string([metadata_get(metadata, :status), activity_status(field(entry, :status))]),
        occurred_at: field(entry, :inserted_at),
        preview: preview_context(field(entry, :source), nil, tool, metadata),
        metadata: metadata,
        identifiers:
          strings([
            session,
            pane,
            metadata_get(metadata, :session_id),
            metadata_get(metadata, :url),
            metadata_get(metadata, :display_url),
            metadata_get(metadata, :screenshot_url),
            metadata_get(metadata, :artifact_url),
            metadata_get(metadata, :tool),
            tool
          ])
      )
    end)
  end

  defp label_candidates(workspace_id, labels_by_session) do
    Enum.flat_map(labels_by_session, fn {session, labels} ->
      labels
      |> Enum.map(fn {key, entry} ->
        pane = pane_from_label_key(key)
        label = field(entry, :label)

        candidate(
          source: :label,
          id: candidate_id("label", key),
          workspace_id: workspace_id,
          session: session,
          pane: pane,
          title: label || "Pane label",
          summary: label_summary(entry),
          status: status_string(field(entry, :status)),
          occurred_at: field(entry, :updated_at),
          metadata: metadata(entry),
          identifiers: strings([session, pane, key])
        )
      end)
    end)
  end

  defp candidate(attrs) do
    attrs = Map.new(attrs)

    %{
      id: attrs.id,
      source: attrs.source,
      workspace_id: attrs.workspace_id,
      session: attrs.session,
      pane: attrs.pane,
      title: attrs.title,
      summary: attrs.summary,
      status: attrs.status,
      occurred_at: attrs.occurred_at,
      preview: Map.get(attrs, :preview),
      metadata: attrs.metadata || %{},
      identifiers: attrs.identifiers || []
    }
  end

  defp rank_candidate(candidate, filters) do
    with true <- source_filter_match?(candidate, filters.source),
         true <- workspace_scope_match?(candidate, filters.workspace_aliases),
         true <- workspace_filter_match?(candidate, filters.workspace, filters.workspace_aliases),
         true <- session_filter_match?(candidate, filters.session),
         true <- pane_filter_match?(candidate, filters.pane),
         true <- date_filter_match?(candidate, filters.since, filters.until),
         matches <- field_matches(candidate, filters.query),
         true <- filters.query == "" or matches != [] do
      matched_fields = Enum.map(matches, fn {field, _value} -> field end)

      candidate
      |> Map.put(:matched_fields, matched_fields)
      |> Map.put(:score, score(matches))
    else
      _ -> nil
    end
  end

  defp field_matches(_candidate, ""), do: []

  defp field_matches(candidate, query) do
    candidate
    |> searchable_fields()
    |> Enum.filter(fn {_field, value} -> contains?(value, query) end)
  end

  defp searchable_fields(candidate) do
    base_fields(candidate) ++
      preview_fields(candidate.preview) ++ metadata_fields(candidate.metadata)
  end

  defp base_fields(candidate) do
    [
      {"id", candidate.id},
      {"source", Atom.to_string(candidate.source)},
      {"title", candidate.title},
      {"summary", candidate.summary},
      {"status", candidate.status},
      {"occurred_at", searchable_value(candidate.occurred_at)},
      {"workspace_id", candidate.workspace_id},
      {"session", candidate.session},
      {"pane", candidate.pane}
    ] ++ Enum.map(candidate.identifiers, &{"identifier", &1})
  end

  defp metadata_fields(metadata) when is_map(metadata) do
    metadata
    |> flatten_metadata("metadata")
    |> Enum.take(80)
  end

  defp metadata_fields(_), do: []

  defp preview_fields(%{} = preview) do
    preview
    |> flatten_metadata("preview")
    |> Enum.take(20)
  end

  defp preview_fields(_preview), do: []

  defp flatten_metadata(%_{} = value, prefix), do: flatten_metadata_scalar(value, prefix)

  defp flatten_metadata(%{} = value, prefix) do
    value
    |> Enum.sort_by(fn {key, _value} -> key_to_string(key) end)
    |> Enum.flat_map(fn {key, child} ->
      flatten_metadata(child, prefix <> "." <> key_to_string(key))
    end)
  end

  defp flatten_metadata(value, prefix) when is_list(value) do
    value
    |> Enum.take(20)
    |> Enum.with_index()
    |> Enum.flat_map(fn {child, index} ->
      flatten_metadata(child, prefix <> "." <> Integer.to_string(index))
    end)
  end

  defp flatten_metadata(value, prefix), do: flatten_metadata_scalar(value, prefix)

  defp flatten_metadata_scalar(value, prefix) do
    case searchable_value(value) do
      nil -> []
      string -> [{prefix, string}]
    end
  end

  defp public_result(candidate) do
    Map.take(candidate, [
      :id,
      :source,
      :workspace_id,
      :session,
      :pane,
      :title,
      :summary,
      :status,
      :occurred_at,
      :preview,
      :metadata,
      :matched_fields,
      :score
    ])
    |> Map.put(:href, result_href(candidate))
  end

  defp result_href(%{workspace_id: workspace_id} = candidate)
       when is_binary(workspace_id) and workspace_id != "" do
    case terminal_href_session(candidate) do
      session when is_binary(session) and session != "" ->
        query =
          %{
            "session" => session,
            "pane" => candidate.pane
          }
          |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
          |> URI.encode_query()

        "/workspaces/#{workspace_id}?#{query}"

      _ ->
        "/workspaces/#{workspace_id}"
    end
  end

  defp result_href(_candidate), do: nil

  defp terminal_href_session(%{preview: %{} = preview, session: session, metadata: metadata}) do
    preview_session_id = metadata_get(preview, :session_id)

    terminal_session =
      first_string([metadata_get(metadata, :session), metadata_get(metadata, :tmux_session)])

    cond do
      terminal_session != nil -> terminal_session
      session == preview_session_id -> nil
      true -> session
    end
  end

  defp terminal_href_session(%{session: session}), do: session
  defp terminal_href_session(_candidate), do: nil

  defp sort_key(%{score: score, occurred_at: occurred_at, id: id}) do
    {-score, -unix_time(occurred_at), id}
  end

  defp score(matches) do
    matches
    |> Enum.map(fn {field, _value} -> field_weight(field) end)
    |> Enum.sum()
  end

  defp field_weight("title"), do: 80
  defp field_weight("summary"), do: 60
  defp field_weight("status"), do: 55
  defp field_weight("preview.tool"), do: 65
  defp field_weight("preview.session_id"), do: 60
  defp field_weight("preview.url"), do: 60
  defp field_weight("preview.display_url"), do: 60
  defp field_weight("preview.screenshot_url"), do: 60
  defp field_weight("preview.artifact_url"), do: 60
  defp field_weight("preview.recording_url"), do: 60
  defp field_weight("preview.recording_path"), do: 60
  defp field_weight("preview.recording_id"), do: 55
  defp field_weight("preview." <> _), do: 45
  defp field_weight("session"), do: 50
  defp field_weight("pane"), do: 50
  defp field_weight("occurred_at"), do: 45
  defp field_weight("identifier"), do: 40
  defp field_weight("id"), do: 30
  defp field_weight("workspace_id"), do: 20
  defp field_weight("source"), do: 10
  defp field_weight("metadata." <> _), do: 35
  defp field_weight(_), do: 1

  defp source_filter_match?(_candidate, []), do: true

  defp source_filter_match?(candidate, sources) do
    source_match? = candidate.source |> Atom.to_string() |> then(&(&1 in sources))

    preview_match? =
      "preview" in sources and is_map(candidate.preview) and map_size(candidate.preview) > 0

    source_match? or preview_match?
  end

  defp workspace_filter_match?(_candidate, "", _aliases), do: true

  defp workspace_filter_match?(candidate, filter, aliases) do
    candidate
    |> workspace_filter_fields(aliases)
    |> strings()
    |> Enum.any?(&contains?(&1, filter))
  end

  defp workspace_scope_match?(candidate, aliases) do
    case strings([candidate.workspace_id]) do
      [] -> true
      values -> Enum.any?(values, &workspace_alias_match?(&1, aliases))
    end
  end

  defp workspace_alias_match?(value, aliases) do
    normalized = String.downcase(value)

    aliases
    |> strings()
    |> Enum.any?(&(String.downcase(&1) == normalized))
  end

  defp workspace_filter_fields(candidate, aliases) do
    [
      candidate.workspace_id,
      aliases,
      workspace_metadata_values(candidate.metadata),
      workspace_metadata_values(candidate.preview)
    ]
    |> List.flatten()
  end

  defp workspace_metadata_values(%{} = metadata) do
    [
      :workspace,
      :workspace_id,
      :workspace_name,
      :workspace_slug,
      :workspace_label,
      :workspace_user,
      :workspace_external_id,
      :manager_workspace_id
    ]
    |> Enum.map(&workspace_metadata_value(metadata, &1))
  end

  defp workspace_metadata_values(_metadata), do: []

  defp workspace_metadata_value(metadata, key) do
    case metadata_get(metadata, key) do
      value when is_binary(value) -> value
      value when is_atom(value) -> value
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp session_filter_match?(_candidate, ""), do: true

  defp session_filter_match?(candidate, filter) do
    [candidate.session, candidate.id | candidate.identifiers]
    |> strings()
    |> Enum.any?(&contains?(&1, filter))
  end

  defp pane_filter_match?(_candidate, ""), do: true

  defp pane_filter_match?(candidate, filter) do
    [candidate.pane | candidate.identifiers]
    |> strings()
    |> Enum.any?(&contains?(&1, filter))
  end

  defp date_filter_match?(%{occurred_at: nil}, since, until) do
    is_nil(since) and is_nil(until)
  end

  defp date_filter_match?(%{occurred_at: occurred_at}, since, until) do
    after_since?(occurred_at, since) and before_until?(occurred_at, until)
  end

  defp after_since?(_occurred_at, nil), do: true
  defp after_since?(occurred_at, since), do: DateTime.compare(occurred_at, since) != :lt

  defp before_until?(_occurred_at, nil), do: true
  defp before_until?(occurred_at, until), do: DateTime.compare(occurred_at, until) != :gt

  defp contains?(value, query) when is_binary(value) and is_binary(query) do
    value
    |> String.downcase()
    |> String.contains?(String.downcase(query))
  end

  defp contains?(_value, _query), do: false

  defp session_summary(session, metadata) do
    [
      field(session, :kind) && "kind=#{field(session, :kind)}",
      field(session, :status) && "status=#{field(session, :status)}",
      metadata_get(metadata, :cwd) && "cwd=#{metadata_get(metadata, :cwd)}",
      metadata_get(metadata, :git_branch) && "branch=#{metadata_get(metadata, :git_branch)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp audit_summary(event) do
    [
      field(event, :action),
      field(event, :target_type),
      field(event, :target_ref),
      decision_summary(event),
      reason_summary(event)
    ]
    |> strings()
    |> Enum.join(" ")
  end

  defp decision_summary(event) do
    case field(event, :decision) do
      nil -> nil
      decision -> "decision=#{decision}"
    end
  end

  defp reason_summary(event) do
    case field(event, :reason) do
      nil -> nil
      reason -> "reason=#{reason}"
    end
  end

  defp label_summary(entry) do
    [
      field(entry, :label),
      field(entry, :source) && "source=#{field(entry, :source)}",
      field(entry, :tool) && "tool=#{field(entry, :tool)}"
    ]
    |> strings()
    |> Enum.join(" ")
  end

  defp action_status(action) when is_binary(action) do
    case action |> String.split(".") |> List.last() do
      "agent_prompt_running" -> "running"
      "agent_prompt_done" -> "done"
      "agent_prompt_attention" -> "attention"
      "agent_prompt_noop" -> "noop"
      _ -> nil
    end
  end

  defp action_status(_action), do: nil

  defp activity_status(:error), do: "error"
  defp activity_status("error"), do: "error"
  defp activity_status(_status), do: nil

  defp preview_context(source, action, tool, metadata) do
    if preview_context?(source, action, tool, metadata) do
      %{
        agent_action: preview_agent_action(action, tool, metadata),
        agent_session:
          first_string([
            metadata_get(metadata, :agent_session),
            metadata_get(metadata, :tmux_session),
            metadata_get(metadata, :session)
          ]),
        agent_pane:
          first_string([
            metadata_get(metadata, :agent_pane),
            metadata_get(metadata, :pane),
            metadata_get(metadata, :pane_id)
          ]),
        tool: first_string([tool, metadata_get(metadata, :tool)]),
        session_id: metadata_get(metadata, :session_id),
        pane: first_string([metadata_get(metadata, :pane), metadata_get(metadata, :pane_id)]),
        title:
          first_string([
            metadata_get(metadata, :preview_title),
            metadata_get(metadata, :page_title),
            metadata_get(metadata, :title)
          ]),
        status:
          first_string([
            metadata_get(metadata, :preview_status),
            metadata_get(metadata, :browser_status),
            metadata_get(metadata, :status)
          ]),
        url: first_string([metadata_get(metadata, :url), metadata_get(metadata, :current_url)]),
        source_url: metadata_get(metadata, :source_url),
        display_url: metadata_get(metadata, :display_url),
        screenshot_url:
          first_string([
            metadata_get(metadata, :screenshot_url),
            metadata_get(metadata, :screenshot)
          ]),
        artifact_url:
          first_string([metadata_get(metadata, :artifact_url), metadata_get(metadata, :artifact)]),
        recording_id: metadata_get(metadata, :recording_id),
        recording_url:
          first_string([
            metadata_get(metadata, :recording_url),
            metadata_get(metadata, :playback_url),
            metadata_get(metadata, :video_url)
          ]),
        recording_path:
          first_string([
            metadata_get(metadata, :recording_path),
            metadata_get(metadata, :artifact_path),
            metadata_get(metadata, :video_path)
          ]),
        recording_status: metadata_get(metadata, :recording_status),
        path: metadata_get(metadata, :path),
        port: metadata_get(metadata, :port),
        surface: metadata_get(metadata, :surface),
        mode: metadata_get(metadata, :mode),
        element_id: metadata_get(metadata, :element_id),
        selector: metadata_get(metadata, :selector)
      }
      |> Enum.reject(fn {_key, value} -> blank_preview_value?(value) end)
      |> Map.new()
      |> empty_to_nil()
    else
      nil
    end
  end

  defp preview_context?(source, action, tool, metadata) do
    source in [:preview_mcp, "preview_mcp"] or
      preview_tool?(tool) or
      preview_action?(action) or
      preview_metadata?(metadata)
  end

  defp preview_tool?(tool) when is_binary(tool) do
    String.starts_with?(tool, "preview_") or tool == "devide_reload_page"
  end

  defp preview_tool?(_tool), do: false

  defp preview_agent_action(action, tool, metadata) do
    first_string([
      metadata_get(metadata, :agent_action),
      metadata_get(metadata, :action),
      action,
      tool
    ])
  end

  defp preview_action?(action) when is_binary(action),
    do: String.starts_with?(action, "agent.preview_")

  defp preview_action?(_action), do: false

  defp preview_metadata?(metadata) when is_map(metadata) do
    Enum.any?(
      [
        :url,
        :current_url,
        :display_url,
        :screenshot_url,
        :artifact_url,
        :recording_id,
        :recording_url,
        :recording_path,
        :surface,
        :mode
      ],
      &(not blank_preview_value?(metadata_get(metadata, &1)))
    )
  end

  defp preview_metadata?(_metadata), do: false

  defp blank_preview_value?(nil), do: true
  defp blank_preview_value?(""), do: true
  defp blank_preview_value?(%{} = map), do: map_size(map) == 0
  defp blank_preview_value?([]), do: true
  defp blank_preview_value?(_value), do: false

  defp empty_to_nil(%{} = map) when map_size(map) == 0, do: nil
  defp empty_to_nil(map), do: map

  defp audit_session(event, metadata) do
    target_ref = field(event, :target_ref)

    first_string([
      metadata_get(metadata, :session),
      metadata_get(metadata, :session_id),
      metadata_get(metadata, :tmux_session),
      target_ref,
      metadata_get(metadata, :run_id)
    ])
  end

  defp activity_session(metadata) do
    first_string([
      metadata_get(metadata, :session),
      metadata_get(metadata, :session_id),
      metadata_get(metadata, :tmux_session)
    ])
  end

  defp session_identifier(session, metadata) do
    first_string([
      field(session, :tmux_session),
      metadata_get(metadata, :tmux_session),
      field(session, :sid),
      field(session, :runner_id),
      field(session, :id)
    ])
  end

  defp pane_from_label_key(key) when is_binary(key) do
    case String.split(key, "::", parts: 2) do
      [_session, pane] when pane != "" -> pane
      _ -> nil
    end
  end

  defp pane_from_label_key(_key), do: nil

  defp candidate_session_ids([sessions, audit_events, activity_entries]) do
    session_ids =
      sessions
      |> Enum.flat_map(fn session ->
        metadata = metadata(session)
        [field(session, :tmux_session), metadata_get(metadata, :tmux_session)]
      end)

    audit_ids =
      audit_events
      |> Enum.flat_map(fn event ->
        metadata = metadata(event)
        [audit_session(event, metadata), metadata_get(metadata, :tmux_session)]
      end)

    activity_ids =
      activity_entries
      |> Enum.flat_map(fn entry ->
        metadata = metadata(entry)
        [activity_session(metadata), metadata_get(metadata, :tmux_session)]
      end)

    [session_ids, audit_ids, activity_ids]
    |> List.flatten()
    |> strings()
    |> Enum.uniq()
  end

  defp read_sessions(workspace_id, opts) do
    cond do
      Keyword.has_key?(opts, :sessions) ->
        Keyword.fetch!(opts, :sessions)

      reader = Keyword.get(opts, :session_reader) ->
        reader.(workspace_id, Keyword.get(opts, :session_reader_opts, []))

      true ->
        safe_call(fn -> SessionDirectory.read(workspace_id, session_directory_opts(opts)) end, [])
    end
  end

  defp read_audit_events(workspace_id, limit, opts) do
    cond do
      Keyword.has_key?(opts, :audit_events) ->
        Keyword.fetch!(opts, :audit_events)

      reader = Keyword.get(opts, :audit_reader) ->
        reader.(workspace_id, limit)

      true ->
        safe_call(fn -> Audit.recent_for(workspace_id, limit) end, [])
    end
  end

  defp read_activity_entries(workspace_id, limit, opts) do
    cond do
      Keyword.has_key?(opts, :activity_entries) ->
        Keyword.fetch!(opts, :activity_entries)

      reader = Keyword.get(opts, :activity_reader) ->
        reader.(workspace_id, limit)

      true ->
        safe_call(fn -> Activity.recent(workspace_id, limit) end, [])
    end
  end

  defp read_labels(sessions, opts) do
    labels_by_session = Keyword.get(opts, :labels_by_session)
    labels_reader = Keyword.get(opts, :labels_reader)

    Enum.reduce(sessions, %{}, fn session, acc ->
      labels =
        cond do
          is_map(labels_by_session) ->
            Map.get(labels_by_session, session, %{})

          is_function(labels_reader, 1) ->
            labels_reader.(session)

          true ->
            safe_call(fn -> Labels.for_session(session) end, %{})
        end

      if map_size(labels) == 0, do: acc, else: Map.put(acc, session, labels)
    end)
  end

  defp session_directory_opts(opts) do
    opts
    |> Keyword.take([:workspace_name, :workspace_names, :tmux_sessions, :directory_inventory])
    |> Keyword.put_new(:directory_inventory, :error)
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: min(value, @max_limit)

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> normalize_limit(int)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit

  defp normalize_source_limit(opts, result_limit) do
    opts
    |> Keyword.get(:source_limit, max(result_limit * 4, @source_limit))
    |> normalize_positive_integer(max(result_limit, @source_limit))
    |> min(1_000)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp normalize_source_filter(nil), do: []
  defp normalize_source_filter(""), do: []

  defp normalize_source_filter(value) when is_binary(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.flat_map(&normalize_source_token/1)
    |> Enum.uniq()
  end

  defp normalize_source_filter(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_source_filter()
  end

  defp normalize_source_filter(values) when is_list(values) do
    values
    |> Enum.flat_map(&normalize_source_filter/1)
    |> Enum.uniq()
  end

  defp normalize_source_filter(_value), do: []

  defp normalize_source_token(value) do
    case normalize_query(value) |> String.downcase() do
      "sessions" -> ["session"]
      "session" -> ["session"]
      "audit" -> ["audit"]
      "audits" -> ["audit"]
      "activity" -> ["activity"]
      "activities" -> ["activity"]
      "label" -> ["label"]
      "labels" -> ["label"]
      "preview" -> ["preview"]
      "browser" -> ["preview"]
      _ -> []
    end
  end

  defp source_filter_value([]), do: nil
  defp source_filter_value([one]), do: one
  defp source_filter_value(sources), do: sources

  defp optional_filter_value(""), do: nil
  defp optional_filter_value(value), do: value

  defp normalize_workspace_aliases(workspace_id, opts) do
    [
      workspace_id,
      Keyword.get(opts, :workspace_alias),
      Keyword.get(opts, :workspace_name),
      Keyword.get(opts, :workspace_aliases),
      Keyword.get(opts, :workspace_names)
    ]
    |> List.flatten()
    |> strings()
    |> Enum.uniq()
  end

  defp normalize_query(nil), do: ""
  defp normalize_query(value) when is_binary(value), do: String.trim(value)
  defp normalize_query(value) when is_atom(value), do: value |> Atom.to_string() |> String.trim()
  defp normalize_query(value), do: value |> to_string() |> String.trim()

  defp datetime_option(opts, keys, boundary) do
    keys
    |> Enum.find_value(fn key -> Keyword.get(opts, key) end)
    |> normalize_datetime(boundary)
  end

  defp normalize_datetime(nil, _boundary), do: nil
  defp normalize_datetime(%DateTime{} = value, _boundary), do: value

  defp normalize_datetime(%NaiveDateTime{} = value, _boundary) do
    DateTime.from_naive!(value, "Etc/UTC")
  end

  defp normalize_datetime(%Date{} = value, boundary), do: date_boundary(value, boundary)

  defp normalize_datetime(value, boundary) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:error, _} <- NaiveDateTime.from_iso8601(value),
         {:error, _} <- Date.from_iso8601(value) do
      nil
    else
      {:ok, %DateTime{} = datetime, _offset} -> datetime
      {:ok, %NaiveDateTime{} = naive} -> DateTime.from_naive!(naive, "Etc/UTC")
      {:ok, %Date{} = date} -> date_boundary(date, boundary)
    end
  end

  defp normalize_datetime(_value, _boundary), do: nil

  defp date_boundary(date, :end), do: DateTime.new!(date, ~T[23:59:59.999999], "Etc/UTC")
  defp date_boundary(date, _start), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp metadata(value) do
    case field(value, :metadata) do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp metadata_get(metadata, key) when is_map(metadata) and is_atom(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp metadata_get(_metadata, _key), do: nil

  defp metadata_time(metadata) when is_map(metadata) do
    metadata
    |> metadata_get(:activity)
    |> unix_datetime()
  end

  defp unix_datetime(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> datetime
      {:error, _} -> nil
    end
  end

  defp unix_datetime(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> unix_datetime(int)
      _ -> nil
    end
  end

  defp unix_datetime(_value), do: nil

  defp field(value, key) when is_map(value) and is_atom(key) do
    case Map.fetch(value, key) do
      {:ok, value} -> value
      :error -> Map.get(value, Atom.to_string(key))
    end
  end

  defp field(_value, _key), do: nil

  defp first_string(values) do
    Enum.find_value(values, fn value ->
      case searchable_value(value) do
        nil -> nil
        "" -> nil
        string -> string
      end
    end)
  end

  defp strings(values) do
    values
    |> Enum.map(&searchable_value/1)
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp searchable_value(nil), do: nil
  defp searchable_value(value) when is_boolean(value), do: Atom.to_string(value)
  defp searchable_value(value) when is_binary(value), do: String.trim(value)
  defp searchable_value(value) when is_atom(value), do: Atom.to_string(value)
  defp searchable_value(value) when is_integer(value), do: Integer.to_string(value)
  defp searchable_value(value) when is_float(value), do: Float.to_string(value)
  defp searchable_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp searchable_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp searchable_value(%Date{} = value), do: Date.to_iso8601(value)
  defp searchable_value(%Time{} = value), do: Time.to_iso8601(value)

  defp searchable_value(value) do
    inspect(value, limit: 20, printable_limit: 200)
  end

  defp status_string(value), do: searchable_value(value)

  defp candidate_id(prefix, nil), do: prefix <> ":unknown"
  defp candidate_id(prefix, value), do: prefix <> ":" <> searchable_value(value)

  defp key_to_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key), do: key
  defp key_to_string(key), do: inspect(key)

  defp unix_time(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp unix_time(_), do: 0

  defp safe_call(fun, default) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
    _kind, _reason -> default
  end
end
