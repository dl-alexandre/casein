defmodule Casein.Agents.TerminalTools.Impl.Session do
  @moduledoc false

  alias Casein.Agents.GrokCapabilityPolicy
  alias Casein.Agents.TerminalOutputFormat
  alias Casein.Labels
  alias Casein.Operator.SituationServer
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.NextPrompt
  alias Casein.Terminals.OrchestrationStatus
  alias Casein.Terminals.OrphanedClaims
  alias Casein.Terminals.PaneLiveness
  alias Casein.Terminals.TmuxTopology

  import Casein.Agents.TerminalTools.Impl.Shared

  @session_prefix "casein_"

  # Session-level active window/pane track the attached operator's focus and
  # move when the operator switches windows. Deictic pane references ("the
  # pane beside me") must anchor to the caller pane, never to session focus.
  @active_pane_note "active_window_id/active_pane_id follow the attached operator's focus and " <>
                      "change when the operator switches windows. Anchor pane references to " <>
                      "caller.adjacent_panes (or an explicit pane id), not to the active pane."

  # Post-#605 the bwrap base is always "strict"; the unlock gates the MCP grant
  # only. Orchestrators that need terminal_send_* must fail fast — not poll.
  @agent_write_blocked_note "Agent write is unavailable for this workspace. A managed Grok pane " <>
                              "launched now still gets a strict sandbox (can write its worktree, " <>
                              "run mix, commit) but its MCP grant omits terminal_send_command / " <>
                              "terminal_send_keys. That grant is frozen at launch — re-granting " <>
                              "does not free a running pane; relaunch after the grant. " <>
                              "ORCHESTRATOR FAIL-FAST: if you need pane control, emit ONE blocked " <>
                              "report, set label 'blocked: need agent-write unlock', and STOP. " <>
                              "Do not schedule 15–30m unlock poll loops."

  @doc "List live Casein-managed tmux sessions."
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
          |> put_agent_write(params)
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
        # Before AgentState: it folds the observed verdict in, so a frozen
        # spinner over a silent worktree resolves to :stalled instead of
        # :working.
        |> put_liveness(params)
        |> AgentState.enrich_topology(session)
        |> NextPrompt.enrich_topology(session)
        |> IssueBinding.enrich_topology(session)
        |> Labels.enrich_topology(session)
        # Fleet chrome is a pure projection over the fields above — role from
        # label/window convention, ready_no_task from idle + no issue + quiet.
        |> put_agent_state_ages(session)
        |> put_window_names_on_panes()
        |> FleetChrome.enrich_topology()
        |> put_window_active_panes()
        |> put_shared_worktree_warning()
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

  # Worktree resolution is cheap and always useful — an orchestrator should not
  # have to shell out to `tmux list-panes` to learn where a window is working.
  # The liveness *walk* is the part that costs, so it stays opt-in.
  defp put_liveness(snapshot, params) do
    PaneLiveness.enrich_topology(snapshot, liveness: truthy?(Map.get(params, :include_liveness)))
  end

  # Several panes in one worktree share a git index. Adoption is deliberate
  # (`scripts/lib/agent-worktree.sh`), so this is a warning, not a refusal — but
  # concurrent git operations corrupt state rather than merely failing, and the
  # only reason the last incident went unnoticed is that nothing said so.
  defp put_shared_worktree_warning(%{panes: panes} = payload) when is_list(panes) do
    case PaneLiveness.shared_worktrees(panes) do
      shared when map_size(shared) == 0 ->
        payload

      shared ->
        Map.put(payload, :shared_worktrees, %{
          paths: shared,
          note:
            "More than one pane is working in the same git worktree. Concurrent git " <>
              "operations there corrupt index state rather than failing cleanly. Give each " <>
              "agent its own worktree unless the sharing is intentional."
        })
    end
  end

  defp put_shared_worktree_warning(payload), do: payload

  # FleetChrome prefers liveness.quiet_for_seconds; without include_liveness the
  # explicit report age still answers "idle how long?" for ready_no_task.
  defp put_agent_state_ages(%{panes: panes} = payload, session) when is_list(panes) do
    reports = AgentState.for_session(session)
    now = DateTime.utc_now()

    %{
      payload
      | panes:
          Enum.map(panes, fn pane ->
            with id when is_binary(id) <- Map.get(pane, :id) || Map.get(pane, "id"),
                 %{reported_at: at} <- Map.get(reports, id) do
              Map.put(pane, :agent_state_age_s, max(DateTime.diff(now, at, :second), 0))
            else
              _ -> pane
            end
          end)
    }
  end

  defp put_agent_state_ages(payload, _session), do: payload

  # Copy tmux window names onto panes so FleetChrome can classify spawn windows
  # named `worker-<slug>` without a second Labels lookup.
  defp put_window_names_on_panes(%{panes: panes, windows: windows} = payload)
       when is_list(panes) and is_list(windows) do
    names =
      for window <- windows,
          id = Map.get(window, :id) || Map.get(window, "id"),
          is_binary(id),
          name = Map.get(window, :name) || Map.get(window, "name"),
          is_binary(name) and name != "",
          into: %{},
          do: {id, name}

    if map_size(names) == 0 do
      payload
    else
      %{
        payload
        | panes:
            Enum.map(panes, fn pane ->
              window_id = Map.get(pane, :window_id) || Map.get(pane, "window_id")

              case Map.get(names, window_id) do
                name when is_binary(name) -> Map.put(pane, :window_name, name)
                _ -> pane
              end
            end)
      }
    end
  end

  defp put_window_names_on_panes(payload), do: payload

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

  @doc """
  Read-only fleet orchestration status (M1): FleetBoard + GateQueue + orphans.

  Requires workspace_id and session. Builds the same enriched topology path as
  `topology/1` with **liveness on by default** (external observation is what
  distinguishes wedged from thinking). Projects window tabs into `FleetBoard`,
  then shapes the wire payload via `OrchestrationStatus.project/2`.

  Optional gate identity keys (`gate_pr` / `gate_run_id` / `gate_branch` /
  `gate_pid`) populate `gate_queue.my_position`. No mutations, no scrollback.
  """
  @spec orchestration_status(map()) :: {:ok, map()} | {:error, term()}
  def orchestration_status(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, session} <- session_arg(params),
         {:ok, topology} <- topology(Map.put_new(params, :include_liveness, true)) do
      tabs = OrchestrationStatus.tabs_from_topology(topology)

      board =
        FleetBoard.from_window_tabs(tabs,
          list_claimed: &OrphanedClaims.list_claimed/0,
          tmux_session: session
        )

      project_opts =
        [
          workspace_id: workspace_id,
          session: session
        ]
        |> maybe_put_gate_identity(params)

      {:ok, OrchestrationStatus.project(board, project_opts)}
    end
  end

  defp maybe_put_gate_identity(opts, params) do
    identity =
      %{
        pr: parse_gate_pr(Map.get(params, :gate_pr) || Map.get(params, "gate_pr")),
        run_id: blank_gate(Map.get(params, :gate_run_id) || Map.get(params, "gate_run_id")),
        branch: blank_gate(Map.get(params, :gate_branch) || Map.get(params, "gate_branch")),
        pid: parse_gate_pid(Map.get(params, :gate_pid) || Map.get(params, "gate_pid"))
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(identity) == 0, do: opts, else: Keyword.put(opts, :gate_identity, identity)
  end

  defp parse_gate_pr(n) when is_integer(n) and n > 0, do: n

  defp parse_gate_pr(n) when is_binary(n) do
    case Integer.parse(String.trim_leading(String.trim(n), "#")) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp parse_gate_pr(_), do: nil

  defp parse_gate_pid(n) when is_integer(n) and n > 0, do: n

  defp parse_gate_pid(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {i, ""} when i > 0 -> i
      _ -> nil
    end
  end

  defp parse_gate_pid(_), do: nil

  defp blank_gate(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp blank_gate(_), do: nil

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

  # The unlock gates the MCP grant (terminal_send_*), not the bwrap base (always
  # strict after #605). The grant is read at leader start and frozen for the
  # pane's life while per-request intersection still tracks live policy for new
  # tools/list. Orienting agents learn the lock here on their first call so an
  # orchestrator can fail fast instead of scheduling unlock polls.
  defp put_agent_write(payload, params) do
    case workspace_id(params) do
      nil -> payload
      workspace_id -> Map.put(payload, :agent_write, agent_write(workspace_id))
    end
  end

  defp agent_write(workspace_id) do
    summary = GrokCapabilityPolicy.agent_write_summary(workspace_id)

    summary
    |> Map.put(:note, agent_write_note(summary.write_enabled, summary.unlock_status))
    |> Map.put(:orchestrator_ready, summary.write_enabled)
    |> Map.put(
      :fail_fast,
      if(summary.write_enabled,
        do: nil,
        else: "blocked: need agent-write unlock — stop; do not poll"
      )
    )
    |> compact()
  end

  defp agent_write_note(true, _status), do: nil

  defp agent_write_note(false, status) do
    @agent_write_blocked_note <> " " <> agent_write_remedy(status)
  end

  # `write_enabled` can be false while the unlock is live: the workspace may not
  # be in manual mode, or its DB isolation may be shared_stage/unsafe. Saying
  # "re-grant the unlock" there sends the operator down a dead end.
  defp agent_write_remedy("active") do
    "The unlock itself is active, so the block is elsewhere — the workspace is not in manual " <>
      "mode, or its DB isolation is shared_stage/unsafe. Re-granting will not help; resolve " <>
      "that first. Fallback without unlock: GitHub/docs-only audit, or use codex (not gated)."
  end

  defp agent_write_remedy(_status) do
    "An operator must grant agent write in the workspace UI (chrome banner Unlock 30 min), " <>
      "then relaunch. Fallback without unlock: GitHub/docs-only audit, or use codex (not gated)."
  end
end
