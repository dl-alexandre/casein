defmodule DevIDE.Agents.PreviewTools.ControlSession.SessionResolve do
  @moduledoc false

  alias DevIDE.Agents.PreviewTools.ControlSession.Shared
  alias DevIDE.Agents.PreviewTools.ControlSession.Visibility
  alias DevIDE.Agents.PreviewTools.TmuxTopology, as: PreviewTmuxTopology
  alias DevIDE.PreviewPanes
  alias DevIDE.PreviewActivity

  def split_opts(params, workspace) do
    tmux_session =
      Shared.string_param(params, :tmux_session) ||
        resolve_tmux_session(workspace, Map.new(params))

    Shared.tool_opts(params, workspace)
    |> Keyword.merge(
      tmux_session: tmux_session,
      workspace_id: Shared.workspace_id(workspace),
      cwd: Map.get(params, "cwd") || Map.get(params, :cwd) || Shared.workspace_host_path(workspace),
      anchor_pane_id: Map.get(params, "anchor_pane_id") || Map.get(params, :anchor_pane_id),
      anchor_window_id: Map.get(params, "anchor_window_id") || Map.get(params, :anchor_window_id),
      placement: Map.get(params, "placement") || Map.get(params, :placement),
      viewport: Map.get(params, "viewport") || Map.get(params, :viewport)
    )
    |> maybe_anchor_scoped_tmux_session()
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp maybe_anchor_scoped_tmux_session(opts) do
    tmux_session = Keyword.get(opts, :tmux_session)

    cond do
      not is_binary(tmux_session) or tmux_session == "" ->
        opts

      Keyword.get(opts, :anchor_pane_id) ->
        opts

      true ->
        case PreviewTmuxTopology.resolve_preview_placement(tmux_session, %{}) do
          {:ok, placement} ->
            opts
            |> Keyword.put(:anchor_pane_id, placement.anchor_pane_id)
            |> Keyword.put(:anchor_window_id, placement.anchor_window_id)
            |> Keyword.put_new(:placement, placement.placement)

          {:error, _reason} ->
            opts
        end
    end
  end

  def workspace_tmux_session(workspace) do
    workspace
    |> workspace_matching_sessions()
    |> pick_workspace_session(Shared.workspace_id(workspace))
  end

  def ensure_unambiguous_tmux_session(workspace, params) do
    if Shared.string_param(params, :tmux_session) do
      :ok
    else
      case workspace_matching_sessions(workspace) do
        [_session] ->
          :ok

        [] ->
          :ok

        sessions ->
          if session_pick_ambiguous?(Shared.workspace_id(workspace), sessions) do
            {:error, ambiguous_tmux_session_error(sessions)}
          else
            :ok
          end
      end
    end
  end

  defp workspace_matching_sessions(workspace) do
    workspace
    |> workspace_session_prefixes()
    |> then(fn prefixes ->
      Shared.terminals().list_sessions()
      |> Enum.filter(fn %{session: name} ->
        Enum.any?(prefixes, &String.starts_with?(name, &1))
      end)
    end)
  end

  defp pick_workspace_session(_sessions, nil), do: nil
  defp pick_workspace_session([], _workspace_id), do: nil

  defp pick_workspace_session([%{session: session}], _workspace_id), do: session

  defp pick_workspace_session(sessions, workspace_id) do
    sessions
    |> Enum.sort_by(&session_pick_key(workspace_id, &1), :asc)
    |> hd()
    |> Map.fetch!(:session)
  end

  defp session_pick_ambiguous?(workspace_id, sessions) when is_binary(workspace_id) do
    ranks =
      Enum.map(sessions, fn %{session: name} ->
        session_visibility_rank(workspace_id, name)
      end)

    top = Enum.max(ranks, fn -> 0 end)
    top > 0 and Enum.count(ranks, &(&1 == top)) > 1
  end

  defp session_pick_ambiguous?(_workspace_id, _sessions), do: false

  defp session_pick_key(workspace_id, %{session: name} = session) do
    visibility_rank = session_visibility_rank(workspace_id, name)
    attached_rank = if Map.get(session, :attached, false), do: 0, else: 1
    activity = -Map.get(session, :activity, 0)
    {-visibility_rank, attached_rank, activity, name}
  end

  defp session_visibility_rank(workspace_id, tmux_session)
       when is_binary(workspace_id) and is_binary(tmux_session) do
    workspace_id
    |> PreviewPanes.list_for_workspace()
    |> Enum.filter(&(&1.tmux_session == tmux_session))
    |> Enum.map(&pane_visibility_rank(workspace_id, &1))
    |> Enum.max(fn -> 0 end)
  end

  defp session_visibility_rank(_workspace_id, _tmux_session), do: 0

  defp pane_visibility_rank(workspace_id, %{pane_id: pane_id}) when is_binary(pane_id) do
    workspace_id
    |> Shared.workspaces().viewer_ids()
    |> Enum.flat_map(&PreviewActivity.recent_pane(&1, pane_id, 5))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.find(&fresh_loaded_visibility?/1)
    |> case do
      %{event: "visibility_heartbeat"} -> 2
      %{event: "iframe_loaded"} -> 1
      _ -> 0
    end
  end

  defp pane_visibility_rank(_workspace_id, _registration), do: 0

  defp fresh_loaded_visibility?(entry) do
    Visibility.fresh_browser_visibility_event?(entry) and Visibility.loaded_browser_visibility_event?(entry)
  end

  def missing_tmux_session_error do
    %{
      error: :missing_tmux_session,
      message:
        "Pass tmux_session or use the session-scoped Preview MCP URL for the calling agent.",
      guidance:
        "Use the session-scoped MCP endpoint so tmux_session is injected automatically, or pass tmux_session from terminal_list_sessions."
    }
  end

  defp ambiguous_tmux_session_error(sessions) do
    session_names =
      sessions
      |> Enum.map(& &1.session)
      |> Enum.sort()

    %{
      error: :ambiguous_tmux_session,
      ambiguous: true,
      candidate_session_names: session_names,
      candidate_sessions: Enum.map(sessions, &tmux_session_candidate/1),
      message:
        "Multiple tmux sessions match this workspace. Pass tmux_session or use the session-scoped Preview MCP URL for the calling agent.",
      guidance:
        "Use preview_open_here from a session-scoped MCP endpoint, or pass one of candidate_session_names as tmux_session."
    }
  end

  defp tmux_session_candidate(%{session: name} = session) do
    %{
      session: name,
      attached: Map.get(session, :attached),
      activity: Map.get(session, :activity)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp workspace_session_prefixes(workspace) do
    id = Shared.workspace_id(workspace)

    prefixes =
      if is_binary(id) and id != "" do
        [Shared.terminals().workspace_session_prefix(id)]
      else
        []
      end

    case Shared.workspaces().get(id) do
      {:ok, ws} ->
        for candidate <- [ws.name, ws.id], is_binary(candidate), candidate != "" do
          Shared.terminals().workspace_session_prefix(candidate)
        end
        |> Enum.concat(prefixes)
        |> Enum.uniq()

      _ ->
        prefixes
    end
  end

  def resolve_tmux_session(workspace, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :tmux_session) do
      Keyword.get(opts, :tmux_session)
    else
      workspace_tmux_session(workspace)
    end
  end

  def resolve_tmux_session(workspace, opts) when is_map(opts) do
    cond do
      Map.has_key?(opts, :tmux_session) -> Map.get(opts, :tmux_session)
      Map.has_key?(opts, "tmux_session") -> Map.get(opts, "tmux_session")
      true -> workspace_tmux_session(workspace)
    end
  end

end
