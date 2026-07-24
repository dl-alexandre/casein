defmodule DevIDE.Agents.TerminalTools.Impl.Session do
  @moduledoc false

  alias DevIDE.Agents.TerminalOutputFormat
  alias DevIDE.Operator.SituationServer
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Terminals.TmuxTopology

  import DevIDE.Agents.TerminalTools.Impl.Shared

  @session_prefix "devide_"

  # Session-level active window/pane track the attached operator's focus and
  # move when the operator switches windows. Deictic pane references ("the
  # pane beside me") must anchor to the caller pane, never to session focus.
  @active_pane_note "active_window_id/active_pane_id follow the attached operator's focus and " <>
                      "change when the operator switches windows. Anchor pane references to " <>
                      "caller.adjacent_panes (or an explicit pane id), not to the active pane."

  @doc "List live DevIDE-managed tmux sessions."
  @spec list_sessions(map()) :: {:ok, map()}
  def list_sessions(params \\ %{}) do
    contains = Map.get(params, "contains") || Map.get(params, :contains)

    sessions =
      tmux().list_sessions()
      |> Enum.filter(&String.starts_with?(&1.session, @session_prefix))
      |> filter_workspace(params)
      |> filter_contains(contains)

    {:ok,
     %{sessions: sessions, workspace_id: workspace_id(params)}
     |> put_session_guidance(params, sessions)
     |> compact()}
  end

  @doc "Return a self-routing terminal context for agent planning."
  @spec context(map()) :: {:ok, map()} | {:error, term()}
  def context(params \\ %{}) do
    sessions = sessions_for(params)

    case session_or_default_arg(params) do
      {:ok, session} ->
        snapshot = enriched_snapshot(session)

        payload =
          %{
            workspace_id: workspace_id(params),
            sessions: Enum.map(sessions, &session_candidate/1),
            recommended_session: session,
            topology: snapshot
          }
          |> put_caller_anchor(snapshot, params)
          |> put_agent_pane_guidance(session, params)
          |> compact()

        {:ok, payload}

      {:error, %{error: :ambiguous_workspace_sessions} = error} ->
        {:ok,
         error
         |> Map.put(:workspace_id, workspace_id(params))
         |> Map.put(:sessions, error.candidate_sessions)
         |> Map.put(:safe_to_mutate, false)
         |> put_ambiguous_recommendation(params)}

      {:error, :no_workspace_sessions} ->
        {:ok,
         %{
           workspace_id: workspace_id(params),
           sessions: [],
           safe_to_mutate: false,
           reason: "no_workspace_sessions",
           next_tool: "terminal_list_sessions",
           next_arguments: compact(%{workspace_id: workspace_id(params)})
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Return a session's window/pane topology."
  @spec topology(map()) :: {:ok, map()} | {:error, term()}
  def topology(params) do
    with {:ok, session} <- session_arg(params) do
      snapshot = TmuxTopology.snapshot(session, tmux: tmux())

      payload =
        snapshot
        |> AgentState.enrich_topology(session)
        |> put_window_active_panes()
        |> Map.put(:active_pane_note, @active_pane_note)
        |> put_caller_anchor(snapshot, params)
        |> put_agent_pane_guidance(session, params)

      {:ok, payload}
    end
  end

  # Direct tmux snapshot plus the semantic agent-state layer. The watcher path
  # (`TmuxTopology.get/2`) stays heuristic-only; enriching here keeps reported
  # :blocked/:done/:idle states visible to MCP consumers without touching it.
  defp enriched_snapshot(session) do
    session
    |> TmuxTopology.snapshot(tmux: tmux())
    |> AgentState.enrich_topology(session)
  end

  # Per-window active panes are stable anchors (they only change when the
  # window's own layout changes); the session-level active pane is not.
  defp put_window_active_panes(payload) do
    case Map.get(payload, :panes) do
      panes when is_list(panes) ->
        Map.put(
          payload,
          :window_active_panes,
          panes |> Enum.filter(& &1.active) |> Map.new(&{&1.window_id, &1.id})
        )

      _ ->
        payload
    end
  end

  # Resolve the caller's own pane in the snapshot and precompute its
  # same-window neighbors so "the pane beside me" is answerable without
  # consulting (operator-following) focus state.
  defp put_caller_anchor(payload, snapshot, params) do
    with pane_id when is_binary(pane_id) <- caller_pane(params),
         panes when is_list(panes) <- Map.get(snapshot, :panes),
         %{} = pane <- Enum.find(panes, &(&1.id == pane_id)) do
      neighbors =
        panes
        |> Enum.filter(&(&1.window_id == pane.window_id and &1.id != pane.id))
        |> Enum.sort_by(&Map.get(&1, :index, 0))
        |> Enum.map(fn neighbor ->
          compact(%{
            id: neighbor.id,
            index: Map.get(neighbor, :index),
            direction: neighbor_direction(pane, neighbor),
            pane_title: Map.get(neighbor, :pane_title),
            current_command: Map.get(neighbor, :current_command),
            pane_state: Map.get(neighbor, :pane_state)
          })
        end)

      Map.put(payload, :caller, %{
        pane: pane.id,
        window_id: pane.window_id,
        adjacent_panes: neighbors,
        note:
          "References like \"the pane beside me\" resolve against adjacent_panes " <>
            "(same window as the caller), not the session active pane."
      })
    else
      _ -> payload
    end
  end

  defp neighbor_direction(anchor, other) do
    geometry = [:left, :top, :width, :height]

    if Enum.all?(geometry, &is_integer(Map.get(anchor, &1))) and
         Enum.all?(geometry, &is_integer(Map.get(other, &1))) do
      cond do
        other.left >= anchor.left + anchor.width -> "right"
        other.left + other.width <= anchor.left -> "left"
        other.top >= anchor.top + anchor.height -> "below"
        other.top + other.height <= anchor.top -> "above"
        true -> "same_window"
      end
    else
      "same_window"
    end
  end

  @doc "Capture a pane's scrollback for a session (defaults to the active pane)."
  @spec capture(map()) :: {:ok, map()} | {:error, term()}
  def capture(params) do
    with {:ok, session} <- session_arg(params),
         {:ok, raw_target} <- target_arg(session, params) do
      # Early-bind implicit targets: resolve "the active pane" to a concrete
      # pane id now, so the result names what was actually read and later
      # operator window switches cannot silently retarget follow-up calls.
      {target, implicit?} = resolve_implicit_target(session, raw_target)
      ansi? = Map.get(params, "ansi", false) == true
      opts = [ansi: ansi?] |> put_lines(lines_param(params))
      output = tmux().capture_scrollback(target, opts) |> TerminalOutputFormat.format(ansi: ansi?)

      {:ok,
       %{session: session, target: target, output: output}
       |> put_implicit_target_warning(implicit?)
       |> put_capture_metadata(output, lines_param(params))
       |> put_next("terminal_capture", capture_next_args(session, target, params))}
    end
  end

  defp put_implicit_target_warning(payload, false), do: payload

  defp put_implicit_target_warning(payload, true) do
    Map.merge(payload, %{
      target_was_active_pane: true,
      targeting_warning:
        "No pane was supplied; resolved to the operator-focused active pane, which follows " <>
          "the operator across windows. Pass an explicit pane id (see terminal_topology " <>
          "caller.adjacent_panes) to anchor the reference."
    })
  end

  @doc """
  The operator situation digest for the scoped workspace — served from the
  live `SituationServer` when `:situation_server` is on, cold-built otherwise.
  """
  @spec workspace_digest(map()) :: {:ok, map()} | {:error, term()}
  def workspace_digest(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params) do
      SituationServer.get_digest(workspace_id)
    end
  end

  defp filter_contains(sessions, nil), do: sessions
  defp filter_contains(sessions, ""), do: sessions

  defp filter_contains(sessions, needle) when is_binary(needle),
    do: Enum.filter(sessions, &String.contains?(&1.session, needle))

  # Ambiguity stays safe-by-default (never an implicit mutation target), but
  # agents still need a starting point: the operator's attached session beats
  # any detached leftover, and recency breaks the remaining ties.
  defp put_ambiguous_recommendation(payload, params) do
    case recommend_session(payload.candidate_sessions) do
      {session, reason} ->
        payload
        |> Map.put(:recommended_session, session)
        |> Map.put(:recommendation_reason, reason)
        |> Map.put(
          :next_arguments,
          compact(%{workspace_id: workspace_id(params), session: session})
        )

      nil ->
        payload
    end
  end

  defp recommend_session(candidates) do
    {pool, reason} =
      case Enum.filter(candidates, &(Map.get(&1, :attached) == true)) do
        [] -> {candidates, "most_recent_activity"}
        [only] -> {[only], "only_attached_session"}
        attached -> {attached, "most_recently_active_attached_session"}
      end

    case Enum.max_by(pool, &(Map.get(&1, :activity) || 0), fn -> nil end) do
      %{session: session} -> {session, reason}
      _ -> nil
    end
  end

  defp put_session_guidance(payload, params, [session]) do
    session_name = session.session

    payload
    |> Map.put(:recommended_session, session_name)
    |> put_next(
      "terminal_context",
      compact(%{workspace_id: workspace_id(params), session: session_name})
    )
  end

  defp put_session_guidance(payload, _params, []),
    do: Map.merge(payload, %{safe_to_mutate: false, reason: "no_workspace_sessions"})

  defp put_session_guidance(payload, _params, sessions) do
    Map.merge(payload, %{
      ambiguous: true,
      safe_to_mutate: false,
      reason: "multiple_sessions",
      candidate_sessions: Enum.map(sessions, &session_candidate/1),
      next_tool: "terminal_context"
    })
  end

  defp put_agent_pane_guidance(payload, session, params) do
    case find_agent_pane(session, params, allow_process_fallback: false) do
      {:ok, pane} ->
        payload
        |> Map.put(:recommended_session, session)
        |> Map.put(:recommended_agent_pane, pane.id)
        |> Map.put(:agent_pane_reason, pane.agent_match)
        |> Map.put(:safe_to_mutate, true)
        |> put_next("terminal_send_agent_command", agent_command_next_args(session, params))

      {:error, reason} ->
        payload
        |> Map.put(:recommended_session, session)
        |> Map.put(:safe_to_mutate, false)
        |> Map.put(:reason, "agent_pair_marker_not_found")
        |> Map.put(:agent_pane_error, error_label(reason))
        |> put_next(
          "terminal_agent_pane",
          compact(%{workspace_id: workspace_id(params), session: session})
        )
    end
  end

  defp error_label(%{error: error}), do: to_string(error)
end
