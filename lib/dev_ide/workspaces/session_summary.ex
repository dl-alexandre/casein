defmodule DevIDE.Workspaces.SessionSummary do
  @moduledoc """
  Compact cross-workspace summary for switchers and pickers.

  This is intentionally a read model: it combines manager workspace data with
  live-but-cheap local observations (tmux sessions, runtimes, git status) and
  returns presentation-ready maps. Mutating terminal/session behavior remains
  in the workspace cockpit.
  """

  alias DevIDE.Agents.Activity
  alias DevIDE.Git
  alias DevIDE.PreviewPanes
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.AgentPane
  alias DevIDE.Terminals.SessionDirectory

  @type summary :: %{
          id: String.t(),
          name: String.t(),
          user: String.t() | nil,
          branch: String.t() | nil,
          status: atom() | String.t() | nil,
          host_id: String.t(),
          path: String.t() | nil,
          path_label: String.t() | nil,
          dirty_count: non_neg_integer() | nil,
          session_count: non_neg_integer(),
          sessions: [map()],
          runtime_count: non_neg_integer(),
          active_runtime_count: non_neg_integer()
        }

  @spec build(map()) :: summary()
  def build(ws) when is_map(ws) do
    build(ws, [])
  end

  defp build(ws, opts) when is_map(ws) do
    id = workspace_id(ws)
    name = workspace_name(ws)
    path = Map.get(ws, :path) || Map.get(ws, :host_path)
    preview_pane_ids = preview_pane_ids(id)
    sessions = sessions(ws, opts)
    agent_activity_by_session = agent_activity_by_session(id)

    session_links =
      Enum.map(sessions, &session_link(ws, &1, preview_pane_ids, agent_activity_by_session))

    runtimes = Runtimes.list_runtimes(%{"workspace_id" => id})

    %{
      id: id,
      name: name,
      user: workspace_user(ws),
      branch: branch(ws, path),
      status: Map.get(ws, :status) || Map.get(ws, :mode),
      host_id: Map.get(ws, :host_id) || Map.get(ws, :host) || "local",
      path: path,
      path_label: path_label(path),
      dirty_count: dirty_count(path),
      session_count: length(sessions),
      sessions: session_links,
      agent_layout: AgentPane.layout_status(session_links),
      runtime_count: length(runtimes),
      active_runtime_count: Enum.count(runtimes, &active_runtime?/1)
    }
  end

  @spec build_many([map()]) :: [summary()]
  def build_many(workspaces) when is_list(workspaces) do
    tmux_sessions = SessionDirectory.list_tmux_sessions()
    directory_inventory = SessionDirectory.directory_inventory()

    workspaces
    |> Task.async_stream(
      &build(&1, tmux_sessions: tmux_sessions, directory_inventory: directory_inventory),
      max_concurrency: System.schedulers_online(),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, summary} -> summary end)
    |> dedupe_aliases()
  end

  @doc """
  Newest attachable shell session id for a workspace, or `nil` when none exist.

  Powers resume-by-default: a bare `/workspaces/{id}` open (dashboard button,
  bookmark, direct link with no `?session=`) reattaches the most-recently-active
  live shell instead of forking a brand-new per-tab session. Read-only agent
  sessions and exited shells are skipped; an explicit `?session=` deep link still
  pins a specific session.
  """
  @spec newest_shell_sid(String.t(), String.t() | nil) :: String.t() | nil
  def newest_shell_sid(workspace_id, workspace_name) when is_binary(workspace_id) do
    workspace_id
    |> SessionDirectory.read(workspace_name: workspace_name || workspace_id)
    |> Enum.filter(&attachable_shell?/1)
    |> Enum.sort_by(&session_activity/1, :desc)
    |> case do
      [%{sid: sid} | _] -> sid
      [] -> nil
    end
  end

  defp attachable_shell?(%{kind: :shell, status: :active, sid: sid})
       when is_binary(sid) and sid != "",
       do: true

  defp attachable_shell?(_), do: false

  @spec orphan_tmux_sessions([summary()]) :: [map()]
  def orphan_tmux_sessions(summaries) when is_list(summaries) do
    known_tmux_sessions =
      summaries
      |> Enum.flat_map(&(Map.get(&1, :sessions) || Map.get(&1, "sessions") || []))
      |> Enum.map(&(Map.get(&1, :tmux_session) || Map.get(&1, "tmux_session")))
      |> Enum.reject(&blank?/1)
      |> MapSet.new()

    SessionDirectory.list_tmux_sessions()
    |> Enum.flat_map(&orphan_tmux_session(&1, known_tmux_sessions))
    |> Enum.sort_by(&session_activity/1, :desc)
  end

  @spec path_label(String.t() | nil) :: String.t() | nil
  def path_label(path) when is_binary(path) and path != "" do
    parts = String.split(path, "/", trim: true)

    case parts do
      [] -> path
      [only] -> only
      _ -> parts |> Enum.take(-2) |> compact_path_tail()
    end
  end

  def path_label(_), do: nil

  defp branch(ws, path) do
    Map.get(ws, :branch) || metadata_value(ws, "branch") || git_branch(path)
  end

  defp git_branch(path) when is_binary(path) and path != "" do
    case Git.branch(path) do
      {:ok, branch} when branch != "" -> branch
      _ -> nil
    end
  end

  defp git_branch(_), do: nil

  defp dirty_count(path) when is_binary(path) and path != "" do
    case Git.status_short(path) do
      {:ok, entries} -> length(entries)
      _ -> nil
    end
  end

  defp dirty_count(_), do: nil

  defp sessions(ws, opts) do
    id = workspace_id(ws)
    name = workspace_name(ws)

    id
    |> SessionDirectory.read(Keyword.merge(opts, workspace_name: name || id))
    |> Enum.sort_by(&session_activity/1, :desc)
  end

  defp orphan_tmux_session(raw, known_tmux_sessions) do
    with session when is_binary(session) and session != "" <- raw_tmux_session_name(raw),
         false <- MapSet.member?(known_tmux_sessions, session),
         {:ok, workspace_name, sid} <- parse_devide_tmux_session(session) do
      [
        %{
          id: "tmux:" <> session,
          kind: :shell,
          label: workspace_name,
          detail: sid,
          href: nil,
          tmux_session: session,
          title: session,
          activity: raw_tmux_activity(raw)
        }
      ]
    else
      _ -> []
    end
  end

  defp raw_tmux_session_name(%{session: session}) when is_binary(session), do: session
  defp raw_tmux_session_name(%{"session" => session}) when is_binary(session), do: session
  defp raw_tmux_session_name(session) when is_binary(session), do: session
  defp raw_tmux_session_name(_raw), do: nil

  defp raw_tmux_activity(%{activity: activity}), do: activity
  defp raw_tmux_activity(%{"activity" => activity}), do: activity
  defp raw_tmux_activity(_raw), do: 0

  defp parse_devide_tmux_session("devide_" <> rest) do
    case String.split(rest, "_") do
      parts when length(parts) >= 2 ->
        sid = List.last(parts)
        workspace_name = parts |> Enum.drop(-1) |> Enum.join("_")

        {:ok, workspace_name, sid}

      _ ->
        :error
    end
  end

  defp parse_devide_tmux_session(_session), do: :error

  defp session_link(ws, session, preview_pane_ids, agent_activity_by_session) do
    id = session_id(session)
    ws_id = workspace_id(ws)
    cwd = session_cwd(session)
    cwd_label = cwd_label(cwd, Map.get(ws, :path) || Map.get(ws, :host_path))
    session_preview_pane_ids = session_preview_pane_ids(session, preview_pane_ids)
    session_alias = session_alias(session)
    agent_activity = session_agent_activity(session, agent_activity_by_session)
    agent_title = agent_activity_title(agent_activity) || session_alias

    %{
      id: id,
      kind: session.kind,
      label: session_display_label(session, cwd_label, session_alias),
      href: session_href(ws_id, Map.get(ws, :host_id) || Map.get(ws, :host), id),
      tmux_session: session.tmux_session,
      cwd: cwd,
      cwd_label: cwd_label,
      branch: session_branch(session),
      agent: session_metadata(session, :agent),
      git_toplevel: session_metadata(session, :git_toplevel),
      git_common_dir: session_metadata(session, :git_common_dir),
      git_head_sha: session_metadata(session, :git_head_sha),
      git_worktree?: session_metadata(session, :git_worktree?),
      git_detached?: session_metadata(session, :git_detached?),
      metadata: session.metadata || %{},
      preview_pane_ids: session_preview_pane_ids,
      title: session_title(session, cwd, session_alias, agent_title),
      agent_title: agent_title,
      agent_pane: agent_activity_pane(agent_activity),
      agent_status: session_agent_status(session, agent_activity)
    }
  end

  defp preview_pane_ids(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> PreviewPanes.list_for_workspace_exact()
    |> Enum.map(& &1.pane_id)
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  catch
    :exit, _ -> MapSet.new()
  end

  defp preview_pane_ids(_workspace_id), do: MapSet.new()

  defp session_preview_pane_ids(session, preview_pane_ids) do
    session
    |> session_window_pane_ids()
    |> Enum.filter(&MapSet.member?(preview_pane_ids, &1))
    |> Enum.uniq()
  end

  defp session_window_pane_ids(session) do
    metadata = session.metadata || %{}
    window_panes = Map.get(metadata, :window_panes) || Map.get(metadata, "window_panes") || %{}

    window_panes
    |> Map.values()
    |> Enum.flat_map(fn
      pane_ids when is_list(pane_ids) -> pane_ids
      _ -> []
    end)
  end

  defp session_href(workspace_id, host_id, session_id) do
    query =
      %{
        "host" => host_query_param(host_id),
        "session" => session_id
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    if query == "",
      do: "/workspaces/#{workspace_id}",
      else: "/workspaces/#{workspace_id}?#{query}"
  end

  defp host_query_param(host_id) when host_id in [nil, "", "local"], do: nil
  defp host_query_param(host_id), do: host_id

  defp dedupe_aliases(summaries) do
    Enum.reduce(summaries, [], fn summary, acc ->
      case Enum.find_index(acc, &duplicate_summary?(&1, summary)) do
        nil ->
          acc ++ [summary]

        index ->
          existing = Enum.at(acc, index)
          List.replace_at(acc, index, richer_summary(existing, summary))
      end
    end)
  end

  defp duplicate_summary?(a, b) do
    a.id == b.id or same_path?(a, b) or same_name_alias?(a, b)
  end

  defp same_path?(a, b) do
    a.host_id == b.host_id and present?(a.path) and a.path == b.path
  end

  defp same_name_alias?(a, b) do
    a.host_id == b.host_id and a.name == b.name and compatible_user?(a.user, b.user) and
      (blank?(a.path) or blank?(b.path) or a.path == b.path)
  end

  defp compatible_user?(nil, _), do: true
  defp compatible_user?("", _), do: true
  defp compatible_user?(_, nil), do: true
  defp compatible_user?(_, ""), do: true
  defp compatible_user?(a, b), do: a == b

  defp richer_summary(a, b) do
    if summary_score(b) > summary_score(a), do: b, else: a
  end

  defp summary_score(summary) do
    [
      present?(summary.path),
      present?(summary.branch),
      is_integer(summary.dirty_count),
      summary.session_count > 0,
      summary.runtime_count > 0,
      present?(summary.user),
      not is_nil(summary.status)
    ]
    |> Enum.count(& &1)
  end

  defp present?(value), do: not blank?(value)
  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false

  defp workspace_id(ws), do: Map.get(ws, :external_id) || Map.get(ws, :id)
  defp workspace_name(ws), do: Map.get(ws, :name) || workspace_id(ws)

  defp workspace_user(ws) do
    Map.get(ws, :user) || metadata_value(ws, "user")
  end

  defp metadata_value(ws, key) do
    metadata = Map.get(ws, :metadata) || Map.get(ws, :manager_payload) || %{}

    Map.get(metadata, key) ||
      get_in(metadata, ["raw", key]) ||
      get_in(metadata, [:raw, key])
  end

  defp session_id(%{kind: :shell, sid: sid}), do: sid
  defp session_id(%{id: id}), do: id

  defp session_activity(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :activity) || Map.get(metadata, "activity") do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_int(value, 0)
      _ -> 0
    end
  end

  defp session_activity(%{activity: value}) when is_integer(value), do: value
  defp session_activity(%{activity: value}) when is_binary(value), do: parse_int(value, 0)

  defp session_activity(_), do: 0

  defp session_cwd(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :cwd) || Map.get(metadata, "cwd") do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _ -> nil
    end
  end

  defp session_cwd(_), do: nil

  defp session_branch(session) do
    case session_metadata(session, :git_branch) do
      branch when is_binary(branch) and branch != "" -> branch
      _ -> nil
    end
  end

  defp session_metadata(%{metadata: metadata}, key) when is_map(metadata) and is_atom(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp session_metadata(_session, _key), do: nil

  defp session_display_label(_session, _label, display_alias)
       when is_binary(display_alias) and display_alias != "",
       do: display_alias

  defp session_display_label(%{kind: :shell}, nil, _display_alias), do: "workspace"
  defp session_display_label(session, nil, _display_alias), do: session_label(session.kind)
  defp session_display_label(_session, label, _display_alias), do: label

  defp cwd_label(cwd, workspace_path) when is_binary(cwd) and cwd != "" do
    cond do
      is_binary(workspace_path) and workspace_path != "" and cwd == workspace_path ->
        Path.basename(cwd)

      is_binary(workspace_path) and workspace_path != "" and
          String.starts_with?(cwd, workspace_path <> "/") ->
        Path.relative_to(cwd, workspace_path)

      true ->
        path_label(cwd)
    end
  end

  defp cwd_label(_, _), do: nil

  defp compact_path_tail(["workspaces", name]), do: name
  defp compact_path_tail(parts), do: Enum.join(parts, "/")

  defp session_title(session, cwd, display_alias, agent_title)
       when is_binary(cwd) and cwd != "" do
    [
      display_alias,
      session_label(session.kind),
      cwd,
      session_branch(session),
      agent_title,
      session_metadata(session, :agent),
      session.tmux_session || session_id(session)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp session_title(session, _cwd, display_alias, agent_title) do
    [display_alias, agent_title, session.tmux_session || session_id(session)]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp session_alias(session) do
    case session_metadata(session, :session_alias) do
      display_alias when is_binary(display_alias) -> String.trim(display_alias)
      _ -> nil
    end
  end

  defp agent_activity_by_session(workspace_id) do
    workspace_id
    |> recent_agent_activity()
    |> Enum.reduce(%{}, fn entry, acc ->
      entry
      |> activity_session_keys()
      |> Enum.reduce(acc, fn session_key, acc -> Map.put_new(acc, session_key, entry) end)
    end)
  end

  defp recent_agent_activity(workspace_id) when is_binary(workspace_id) do
    Activity.recent(workspace_id, 30)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp recent_agent_activity(_workspace_id), do: []

  defp activity_session_keys(entry) when is_map(entry) do
    metadata = activity_metadata(entry)

    [
      metadata_get(metadata, :session),
      metadata_get(metadata, :session_id),
      metadata_get(metadata, :tmux_session)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp activity_session_keys(_entry), do: []

  defp session_agent_activity(session, activity_by_session) do
    session
    |> session_activity_keys()
    |> Enum.find_value(&Map.get(activity_by_session, &1))
  end

  defp session_activity_keys(session) do
    [
      session.tmux_session,
      session_id(session),
      Map.get(session, :sid),
      Map.get(session, :runner_id),
      session_metadata(session, :runtime_id)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.uniq()
  end

  defp agent_activity_title(nil), do: nil

  defp agent_activity_title(entry) do
    metadata = activity_metadata(entry)

    first_present([
      metadata_get(metadata, :title),
      metadata_get(metadata, :prompt_excerpt),
      Map.get(entry, :summary)
    ])
  end

  defp agent_activity_pane(nil), do: nil

  defp agent_activity_pane(entry) do
    metadata = activity_metadata(entry)

    first_present([
      metadata_get(metadata, :pane),
      metadata_get(metadata, :pane_id)
    ])
  end

  defp session_agent_status(session, nil) do
    cond do
      session.status == :error ->
        "attention"

      agent_like_session?(session) and session.status == :exited ->
        "done"

      agent_like_session?(session) and session.status == :active ->
        "running"

      true ->
        nil
    end
  end

  defp session_agent_status(_session, entry) do
    metadata = activity_metadata(entry)

    case first_present([metadata_get(metadata, :status), Map.get(entry, :status)]) do
      "attention" -> "attention"
      "error" -> "attention"
      :error -> "attention"
      "done" -> "done"
      "ok" -> "done"
      :ok -> "done"
      "noop" -> "noop"
      other when is_binary(other) -> other
      _ -> nil
    end
  end

  defp agent_like_session?(session) do
    session.kind == :agent or present?(session_metadata(session, :agent)) or
      present?(session_metadata(session, :session_alias))
  end

  defp activity_metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp activity_metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  defp activity_metadata(_entry), do: %{}

  defp metadata_get(metadata, key) when is_map(metadata) and is_atom(key) do
    case Map.fetch(metadata, key) do
      {:ok, value} -> value
      :error -> Map.get(metadata, Atom.to_string(key))
    end
  end

  defp metadata_get(_metadata, _key), do: nil

  defp first_present(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value when is_atom(value) ->
        value

      _ ->
        nil
    end)
  end

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> default
    end
  end

  defp session_label(:shell), do: "Shell"
  defp session_label(:agent), do: "Agent"
  defp session_label(kind) when is_atom(kind), do: kind |> Atom.to_string() |> String.capitalize()
  defp session_label(kind), do: to_string(kind)

  defp active_runtime?(%{status: status}) when status in ["active", "bound", "provisioned"],
    do: true

  defp active_runtime?(_runtime), do: false
end
