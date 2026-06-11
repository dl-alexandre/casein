defmodule DevIDE.Workspaces.SessionSummary do
  @moduledoc """
  Compact cross-workspace summary for switchers and pickers.

  This is intentionally a read model: it combines manager workspace data with
  live-but-cheap local observations (tmux sessions, runtimes, git status) and
  returns presentation-ready maps. Mutating terminal/session behavior remains
  in the workspace cockpit.
  """

  alias DevIDE.Git
  alias DevIDE.Runtimes
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
    id = workspace_id(ws)
    name = workspace_name(ws)
    path = Map.get(ws, :path) || Map.get(ws, :host_path)
    sessions = sessions(ws)
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
      sessions: Enum.map(sessions, &session_link(ws, &1)),
      runtime_count: length(runtimes),
      active_runtime_count: Enum.count(runtimes, &active_runtime?/1)
    }
  end

  @spec build_many([map()]) :: [summary()]
  def build_many(workspaces) when is_list(workspaces) do
    workspaces
    |> Enum.map(&build/1)
    |> dedupe_aliases()
  end

  @spec path_label(String.t() | nil) :: String.t() | nil
  def path_label(path) when is_binary(path) and path != "" do
    parts = String.split(path, "/", trim: true)

    case parts do
      [] -> path
      [only] -> only
      _ -> Enum.take(parts, -2) |> Enum.join("/")
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

  defp sessions(ws) do
    id = workspace_id(ws)
    name = workspace_name(ws)

    id
    |> SessionDirectory.read(workspace_name: name || id)
    |> Enum.sort_by(&session_activity/1, :desc)
  end

  defp session_link(ws, session) do
    id = session_id(session)
    ws_id = workspace_id(ws)
    cwd = session_cwd(session)
    cwd_label = cwd_label(cwd, Map.get(ws, :path) || Map.get(ws, :host_path))

    %{
      id: id,
      kind: session.kind,
      label: cwd_label || session_label(session.kind),
      href:
        "/workspaces/#{ws_id}?" <>
          URI.encode_query(%{
            "host" => Map.get(ws, :host_id) || Map.get(ws, :host) || "local",
            "session" => id
          }),
      tmux_session: session.tmux_session,
      cwd: cwd,
      cwd_label: cwd_label,
      title: session_title(session, cwd)
    }
  end

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

  defp session_activity(_), do: 0

  defp session_cwd(%{metadata: metadata}) when is_map(metadata) do
    case Map.get(metadata, :cwd) || Map.get(metadata, "cwd") do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _ -> nil
    end
  end

  defp session_cwd(_), do: nil

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

  defp session_title(session, cwd) when is_binary(cwd) and cwd != "" do
    [session_label(session.kind), cwd, session.tmux_session || session_id(session)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" · ")
  end

  defp session_title(session, _cwd), do: session.tmux_session || session_id(session)

  defp parse_int(value, default) do
    case Integer.parse(value) do
      {integer, _} -> integer
      :error -> default
    end
  end

  defp session_label(:shell), do: "Shell"
  defp session_label(:execution), do: "Exec"
  defp session_label(:agent), do: "Agent"
  defp session_label(kind) when is_atom(kind), do: kind |> Atom.to_string() |> String.capitalize()
  defp session_label(kind), do: to_string(kind)

  defp active_runtime?(%{status: status}) when status in ["active", "bound", "provisioned"],
    do: true

  defp active_runtime?(_runtime), do: false
end
