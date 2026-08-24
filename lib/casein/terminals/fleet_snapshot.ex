defmodule Casein.Terminals.FleetSnapshot do
  @moduledoc """
  Timer-refreshed fleet aggregate served from ETS — never computed per request.

  `orchestration_status`, `orchestration_list_workers`, and
  `casein://fleet/summary` used to walk tmux + worktrees + git + progress on
  every MCP call. At ~100 panes that hangs past the client timeout. This
  module keeps one host-wide snapshot warm on a timer; reads are ETS lookups
  that return within milliseconds.

  Contract:

    * every payload carries `generated_at`
    * a missing, partial, or over-budget refresh returns `incomplete: true`
      plus a reason — never an empty-ok that looks like a quiet fleet
    * `needs_you_only: true` reads a precomputed index (no board walk)
    * empty `needs_you` with `needs_you_observe_state: "ok"` is genuinely
      empty; `"unknown"` means the snapshot could not be computed
  """

  use GenServer

  alias Casein.Agents.TerminalTools.Impl.Shared
  alias Casein.Labels
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.FleetBoard
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.FleetSummary
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.OrchestrationListWorkers
  alias Casein.Terminals.OrchestrationStatus
  alias Casein.Terminals.OrphanedClaims
  alias Casein.Terminals.PaneLiveness
  alias Casein.Terminals.PaneState
  alias Casein.Terminals.TmuxTopology

  @table :casein_fleet_snapshot
  @snapshot_key :current
  @default_interval_ms 2_000
  @default_budget_ms 4_000

  @type snapshot :: %{
          generated_at: String.t(),
          incomplete: boolean(),
          incomplete_reason: String.t() | nil,
          boards: %{optional(String.t()) => FleetBoard.board()},
          needs_you: %{optional(String.t()) => [map()]},
          totals: %{optional(String.t()) => non_neg_integer()},
          summary: map()
        }

  ## Public read API (ETS only — never rebuilds)

  @doc "Create the snapshot table (called from application start)."
  @spec ensure_table!() :: :ok
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Pure ETS read of the last landed snapshot. `nil` when none has landed."
  @spec cached() :: snapshot() | nil
  def cached do
    ensure_table!()

    case :ets.lookup(@table, @snapshot_key) do
      [{_, snapshot}] -> snapshot
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "Replace the landed snapshot (refresh path and tests)."
  @spec put(snapshot()) :: :ok
  def put(snapshot) when is_map(snapshot) do
    ensure_table!()
    true = :ets.insert(@table, {@snapshot_key, snapshot})
    :ok
  end

  @doc "Drop the landed snapshot (tests)."
  @spec delete() :: :ok
  def delete do
    ensure_table!()
    :ets.delete(@table, @snapshot_key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Project `orchestration_status` from the landed snapshot.

  Never walks tmux. Missing snapshot or a session not yet scanned returns
  `incomplete: true` with a reason — not a cold topology rebuild.
  """
  @spec orchestration_status(String.t(), String.t(), keyword()) :: map()
  def orchestration_status(workspace_id, session, opts \\ [])
      when is_binary(workspace_id) and is_binary(session) do
    case cached() do
      nil ->
        incomplete_status(workspace_id, session, "snapshot_unavailable", opts)

      snapshot ->
        case Map.get(snapshot.boards, session) do
          nil ->
            incomplete_status(workspace_id, session, "session_not_in_snapshot", opts)

          board ->
            OrchestrationStatus.project(
              board,
              project_opts(workspace_id, session, snapshot, opts)
            )
        end
    end
  end

  @doc """
  Project `orchestration_list_workers` from the landed snapshot.

  `needs_you_only: true` is the cheap path: it returns the precomputed
  index and never loads the full board.
  """
  @spec orchestration_list_workers(String.t(), String.t(), keyword()) :: map()
  def orchestration_list_workers(workspace_id, session, opts \\ [])
      when is_binary(workspace_id) and is_binary(session) do
    if Keyword.get(opts, :needs_you_only) == true do
      needs_you_only(workspace_id, session, opts)
    else
      list_workers_from_board(workspace_id, session, opts)
    end
  end

  @doc """
  Serve `casein://fleet/summary` from the landed snapshot.

  Filters to `workspace_id` when given. A missing snapshot is incomplete,
  never an empty-ok fleet.
  """
  @spec fleet_summary(String.t() | nil) :: map()
  def fleet_summary(workspace_id) do
    case cached() do
      nil ->
        incomplete_summary(workspace_id, "snapshot_unavailable")

      snapshot ->
        filter_summary(snapshot.summary, workspace_id, snapshot)
    end
  end

  ## Refresh / build (timer and tests)

  @doc "Rebuild the host-wide snapshot and land it. Used by the timer and tests."
  @spec refresh(keyword()) :: snapshot()
  def refresh(opts \\ []) do
    snapshot = build(opts)
    put(snapshot)
    snapshot
  end

  @doc """
  Build a snapshot without landing it.

  Options:

    * `:now` — `DateTime` stamped on `generated_at`
    * `:budget_ms` — stop scanning sessions after this many ms
    * `:sessions` — inject session metas (tests)
    * `:tmux` — topology adapter override
    * `:list_claimed` — orphaned-claims port (tests)
    * `:gate_queue` — precomputed gate snapshot (tests)
    * `:topology` — `%{session => topology}` inject (tests; skips tmux)
  """
  @spec build(keyword()) :: snapshot()
  def build(opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    generated_at = DateTime.to_iso8601(now)
    deadline = System.monotonic_time(:millisecond) + budget_ms(opts)

    {by_session, incomplete, reason} =
      opts
      |> session_metas()
      |> Enum.reduce_while({%{}, false, nil}, &scan_session(&1, &2, deadline, opts))

    boards = Map.new(by_session, fn {name, snap} -> {name, snap.board} end)
    needs_you = Map.new(by_session, fn {name, snap} -> {name, snap.needs_you} end)
    totals = Map.new(by_session, fn {name, snap} -> {name, snap.total} end)
    summary_sessions = Enum.map(by_session, fn {_name, snap} -> snap.summary_session end)
    panes = Enum.flat_map(summary_sessions, & &1.panes)

    %{
      generated_at: generated_at,
      incomplete: incomplete,
      incomplete_reason: reason,
      boards: boards,
      needs_you: needs_you,
      totals: totals,
      summary: %{
        uri: FleetSummary.resource_uri(),
        workspace_id: Keyword.get(opts, :workspace_id),
        generated_at: generated_at,
        incomplete: incomplete,
        incomplete_reason: reason,
        session_count: length(summary_sessions),
        pane_count: length(panes),
        sessions: summary_sessions,
        note:
          "Read-only fleet summary from FleetSnapshot. generated_at is the last " <>
            "refresh. incomplete=true means a partial scan — not an empty fleet."
      }
    }
  end

  ## GenServer (timer)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    ensure_table!()
    interval = interval_ms(opts)

    if refresh_on_start?(opts) do
      send(self(), :refresh)
    end

    {:ok,
     %{
       interval_ms: interval,
       budget_ms: budget_ms(opts),
       refreshing?: false,
       timer: schedule_refresh(interval)
     }}
  end

  @impl true
  def handle_info(:refresh, %{refreshing?: true} = state) do
    {:noreply, %{state | timer: schedule_refresh(state.interval_ms)}}
  end

  def handle_info(:refresh, state) do
    parent = self()
    budget = state.budget_ms

    _ =
      Task.start(fn ->
        try do
          refresh(budget_ms: budget)
        after
          send(parent, :refresh_done)
        end
      end)

    {:noreply, %{state | refreshing?: true, timer: schedule_refresh(state.interval_ms)}}
  end

  def handle_info(:refresh_done, state) do
    {:noreply, %{state | refreshing?: false}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals — reads

  defp needs_you_only(workspace_id, session, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    case cached() do
      nil ->
        incomplete_list(workspace_id, session, "snapshot_unavailable", now, true)

      snapshot ->
        serve_needs_you(snapshot, workspace_id, session, now)
    end
  end

  defp serve_needs_you(snapshot, workspace_id, session, now) do
    scanned? =
      Map.has_key?(snapshot.needs_you, session) or Map.has_key?(snapshot.boards, session)

    if scanned? do
      needs_you_payload(snapshot, workspace_id, session)
    else
      incomplete_list(workspace_id, session, "session_not_in_snapshot", now, true)
    end
  end

  defp needs_you_payload(snapshot, workspace_id, session) do
    workers = Map.get(snapshot.needs_you, session) || []
    observe = if snapshot.incomplete, do: "unknown", else: "ok"

    %{
      workspace_id: workspace_id,
      session: session,
      generated_at: snapshot.generated_at,
      incomplete: snapshot.incomplete == true,
      incomplete_reason: snapshot.incomplete_reason,
      needs_you_observe_state: observe,
      total: Map.get(snapshot.totals, session, 0),
      filtered_total: length(workers),
      workers: workers,
      filters: %{needs_you_only: true},
      note:
        "M3 compact worker list from FleetSnapshot needs_you index. " <>
          "needs_you_observe_state=unknown means the snapshot is incomplete, " <>
          "not that nobody needs you."
    }
  end

  defp list_workers_from_board(workspace_id, session, opts) do
    case cached() do
      nil ->
        incomplete_list(
          workspace_id,
          session,
          "snapshot_unavailable",
          Keyword.get(opts, :now) || DateTime.utc_now(),
          Keyword.get(opts, :needs_you_only) == true
        )

      snapshot ->
        case Map.get(snapshot.boards, session) do
          nil ->
            incomplete_list(
              workspace_id,
              session,
              "session_not_in_snapshot",
              Keyword.get(opts, :now) || DateTime.utc_now(),
              Keyword.get(opts, :needs_you_only) == true
            )

          board ->
            OrchestrationListWorkers.project(
              board,
              project_opts(workspace_id, session, snapshot, opts)
            )
        end
    end
  end

  defp project_opts(workspace_id, session, snapshot, opts) do
    opts
    |> Keyword.put(:workspace_id, workspace_id)
    |> Keyword.put(:session, session)
    |> Keyword.put_new(:now, generated_at_dt(snapshot.generated_at))
    |> Keyword.put(:incomplete, snapshot.incomplete == true)
    |> Keyword.put(:incomplete_reason, snapshot.incomplete_reason)
  end

  defp generated_at_dt(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp generated_at_dt(_), do: DateTime.utc_now()

  defp incomplete_status(workspace_id, session, reason, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    OrchestrationStatus.project(FleetBoard.empty(),
      workspace_id: workspace_id,
      session: session,
      now: now,
      incomplete: true,
      incomplete_reason: reason
    )
  end

  defp incomplete_list(workspace_id, session, reason, now, needs_you_only?) do
    OrchestrationListWorkers.project(FleetBoard.empty(),
      workspace_id: workspace_id,
      session: session,
      now: now,
      incomplete: true,
      incomplete_reason: reason,
      needs_you_only: needs_you_only?
    )
  end

  defp incomplete_summary(workspace_id, reason) do
    %{
      uri: FleetSummary.resource_uri(),
      workspace_id: workspace_id,
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      incomplete: true,
      incomplete_reason: reason,
      session_count: 0,
      pane_count: 0,
      sessions: [],
      note: "Fleet summary snapshot unavailable. incomplete=true — this is not an empty fleet."
    }
  end

  defp filter_summary(summary, nil, _snapshot), do: summary

  defp filter_summary(%{workspace_id: workspace_id} = summary, workspace_id, _snapshot)
       when is_binary(workspace_id) do
    summary
  end

  defp filter_summary(summary, workspace_id, snapshot) when is_binary(workspace_id) do
    sessions = Map.get(summary, :sessions) || []

    filtered = filter_workspace_sessions(sessions, workspace_id)

    case filtered do
      :error ->
        %{
          summary
          | workspace_id: workspace_id,
            incomplete: true,
            incomplete_reason: "workspace_filter_failed"
        }

      list when is_list(list) ->
        panes = Enum.flat_map(list, &(Map.get(&1, :panes) || []))

        %{
          summary
          | workspace_id: workspace_id,
            sessions: list,
            session_count: length(list),
            pane_count: length(panes),
            incomplete: snapshot.incomplete == true,
            incomplete_reason: snapshot.incomplete_reason
        }
    end
  end

  ## Internals — build

  defp build_session(session, opts) when is_binary(session) do
    topology = session_topology(session, opts)
    topology = enrich_topology(topology, session)
    tabs = OrchestrationStatus.tabs_from_topology(topology)

    board =
      FleetBoard.from_window_tabs(
        tabs,
        board_opts(session, opts)
      )

    list =
      OrchestrationListWorkers.project(board,
        workspace_id: Keyword.get(opts, :workspace_id) || "fleet",
        session: session,
        now: Keyword.get(opts, :now) || DateTime.utc_now(),
        needs_you_only: true
      )

    {:ok,
     %{
       board: board,
       needs_you: list.workers,
       total: board.total,
       summary_session: summary_session(session, topology)
     }}
  rescue
    _ -> {:error, :build_failed}
  end

  defp board_opts(session, opts) do
    []
    |> then(fn acc ->
      case Keyword.get(opts, :list_claimed) do
        fun when is_function(fun) -> Keyword.put(acc, :list_claimed, fun)
        _ -> Keyword.put(acc, :list_claimed, &OrphanedClaims.cached_list/0)
      end
    end)
    |> then(fn acc ->
      case Keyword.get(opts, :gate_queue) do
        gate when is_map(gate) -> Keyword.put(acc, :gate_queue, gate)
        _ -> acc
      end
    end)
    |> Keyword.put(:tmux_session, session)
  end

  defp session_topology(session, opts) do
    case Keyword.get(opts, :topology) do
      %{} = injected ->
        Map.get(injected, session) || empty_topology(session)

      _ ->
        cheap_topology(session, opts)
    end
  end

  defp cheap_topology(session, opts) do
    case Keyword.get(opts, :tmux) do
      nil ->
        try do
          TmuxTopology.get(session)
        rescue
          _ ->
            TmuxTopology.snapshot(session)
        end

      tmux ->
        TmuxTopology.snapshot(session, tmux: tmux)
    end
  rescue
    _ -> empty_topology(session)
  end

  defp enrich_topology(topology, session) do
    topology
    |> merge_cached_liveness(session)
    |> then(fn snap ->
      _ = PaneLiveness.refresh_async(session, Map.get(snap, :panes) || [])
      snap
    end)
    |> safe_enrich(&AgentState.enrich_topology(&1, session))
    |> safe_enrich(&IssueBinding.enrich_topology(&1, session))
    |> safe_enrich(&Labels.enrich_topology(&1, session))
    |> put_window_names_on_panes()
    |> FleetChrome.enrich_topology()
  end

  defp merge_cached_liveness(%{panes: panes} = topology, session) when is_list(panes) do
    cached = PaneLiveness.cached(session)

    if map_size(cached) == 0 do
      topology
    else
      %{topology | panes: Enum.map(panes, &apply_cached_liveness(&1, cached))}
    end
  end

  defp merge_cached_liveness(topology, _session), do: topology

  defp apply_cached_liveness(pane, cached) do
    case Map.get(cached, PaneState.map_get(pane, :id)) do
      %{liveness: live} = entry ->
        pane
        |> Map.put(:liveness, live)
        |> maybe_put_worktree(Map.get(entry, :worktree_path))

      _ ->
        pane
    end
  end

  defp scan_session(meta, {acc, _inc, _reason}, deadline, opts) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:halt, {acc, true, "refresh_budget_exceeded"}}
    else
      acc_session(session_name(meta), acc, opts)
    end
  end

  defp acc_session(name, acc, opts) do
    case build_session(name, opts) do
      {:ok, session_snap} ->
        {:cont, {Map.put(acc, name, session_snap), false, nil}}

      {:error, _} ->
        {:cont, {acc, true, "session_refresh_failed"}}
    end
  end

  defp filter_workspace_sessions(sessions, workspace_id) do
    Shared.filter_workspace(sessions, %{"workspace_id" => workspace_id})
  rescue
    exception in [RuntimeError, ArgumentError] ->
      _ = exception
      :error
  end

  defp maybe_put_worktree(pane, path) when is_binary(path) and path != "" do
    if is_nil(PaneState.map_get(pane, :worktree_path)) do
      Map.put(pane, :worktree_path, path)
    else
      pane
    end
  end

  defp maybe_put_worktree(pane, _), do: pane

  defp safe_enrich(topology, fun) do
    fun.(topology)
  rescue
    _ -> topology
  end

  defp put_window_names_on_panes(%{panes: panes, windows: windows} = topology)
       when is_list(panes) and is_list(windows) do
    names =
      Map.new(windows, fn w ->
        {Map.get(w, :id) || Map.get(w, "id"), Map.get(w, :name) || Map.get(w, "name")}
      end)

    panes =
      Enum.map(panes, fn pane ->
        case Map.get(names, PaneState.map_get(pane, :window_id)) do
          name when is_binary(name) -> Map.put(pane, :window_name, name)
          _ -> pane
        end
      end)

    %{topology | panes: panes}
  end

  defp put_window_names_on_panes(topology), do: topology

  defp summary_session(session, topology) do
    panes = Enum.map(topology.panes || [], &summary_pane/1)

    %{
      session: session,
      active_window_id: Map.get(topology, :active_window_id),
      active_pane_id: Map.get(topology, :active_pane_id),
      window_count: length(Map.get(topology, :windows) || []),
      pane_count: length(panes),
      panes: panes
    }
    |> reject_nils()
  end

  defp summary_pane(pane) do
    %{
      pane_id: PaneState.map_get(pane, :id),
      window_id: PaneState.map_get(pane, :window_id),
      window_name: PaneState.map_get(pane, :window_name),
      role: stringify(PaneState.map_get(pane, :role)),
      current_command: PaneState.map_get(pane, :current_command),
      agent_state: stringify(PaneState.map_get(pane, :agent_state)),
      label: PaneState.map_get(pane, :label),
      issue: PaneState.map_get(pane, :issue),
      issue_title: PaneState.map_get(pane, :issue_title),
      task_summary: PaneState.map_get(pane, :task_summary),
      fleet_role: stringify(PaneState.map_get(pane, :fleet_role)),
      fleet_readiness: stringify(PaneState.map_get(pane, :fleet_readiness)),
      worktree_path: PaneState.map_get(pane, :worktree_path),
      liveness: liveness_json(PaneState.map_get(pane, :liveness))
    }
    |> reject_nils()
  end

  defp liveness_json(nil), do: nil

  defp liveness_json(live) when is_map(live) do
    %{
      state: stringify(Map.get(live, :state) || Map.get(live, "state")) || "unknown",
      reason: stringify(Map.get(live, :reason) || Map.get(live, "reason")),
      quiet_for_seconds: Map.get(live, :quiet_for_seconds) || Map.get(live, "quiet_for_seconds")
    }
    |> reject_nils()
  end

  defp liveness_json(_), do: %{state: "unknown"}

  defp session_metas(opts) do
    case Keyword.get(opts, :sessions) do
      list when is_list(list) ->
        list

      _ ->
        adapter = Keyword.get(opts, :tmux) || Shared.tmux()

        adapter.list_sessions()
        |> Enum.flat_map(&normalize_session_meta/1)
        |> Enum.filter(&String.starts_with?(&1.session, "casein_"))
    end
  rescue
    _ -> []
  end

  defp normalize_session_meta(%{session: name} = meta) when is_binary(name), do: [meta]

  defp normalize_session_meta(%{"session" => name}) when is_binary(name),
    do: [%{session: name}]

  defp normalize_session_meta(name) when is_binary(name), do: [%{session: name}]
  defp normalize_session_meta(_), do: []

  defp session_name(%{session: name}) when is_binary(name), do: name
  defp session_name(%{"session" => name}) when is_binary(name), do: name
  defp session_name(name) when is_binary(name), do: name
  defp session_name(_), do: ""

  defp empty_topology(session) do
    %{
      session: session,
      windows: [],
      panes: [],
      active_window_id: nil,
      active_pane_id: nil,
      version: 0,
      structure_version: 0,
      layout_version: 0
    }
  end

  defp stringify(nil), do: nil
  defp stringify(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v), do: to_string(v)

  defp reject_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp config do
    Application.get_env(:casein, :fleet_snapshot, [])
  end

  defp interval_ms(opts) do
    Keyword.get(opts, :interval_ms) ||
      Keyword.get(config(), :interval_ms, @default_interval_ms)
  end

  defp budget_ms(opts) do
    Keyword.get(opts, :budget_ms) ||
      Keyword.get(config(), :budget_ms, @default_budget_ms)
  end

  defp refresh_on_start?(opts) do
    Keyword.get(opts, :refresh_on_start, Keyword.get(config(), :refresh_on_start, true))
  end

  defp schedule_refresh(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :refresh, interval)
  end

  defp schedule_refresh(_), do: nil
end
