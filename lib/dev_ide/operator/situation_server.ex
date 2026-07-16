defmodule DevIDE.Operator.SituationServer do
  @moduledoc """
  Live per-workspace situation model behind the operator digest.

  Holds the latest `DevIDE.Operator.SituationDigest` and keeps it warm from
  push signals instead of cold-rebuilding per request. Started on demand by
  the first `get_digest/1` when the `:situation_server` flag
  (`DEV_IDE_SITUATION_SERVER`) is on; with the flag off nothing starts and
  callers keep the Phase-0 cold build.

  Fan-in (first production consumer of the `SessionEvents` bus):

    * `DevIDE.Terminals.SessionEvents` per workspace session — output
      generation/freshness per sid (feeds the `:working_no_output` detector)
    * `"agent_state:<ws>"` — semantic pane-state reports, applied to the
      digest in place and tracked with their `reported_at` (feeds
      `:blocked_too_long`)
    * `"agent_activity:<ws>"` — MCP tool-call tail, prepended in place
    * `DevIDE.Audit.subscribe/1` — refreshes `activity.last_mutation`
    * `"deploy:updates"` — recomputes the digest's deploy section
    * `DevIDE.Terminals.TmuxTopology` + `DevIDE.Terminals.SessionDirectory`
      topics (passive) — topology-shaped changes debounce a full rebuild

  Cheap signals mutate the digest incrementally; structural ones debounce
  (#{250}ms) a full `SituationDigest.build/1`, which also re-syncs the
  session subscriptions to the sessions that exist now. `generated_at` and
  `freshness` describe the last *full* rebuild — incremental patches update
  sections without re-dating the digest.

  Detector engine: on relevant changes (debounced) and on a periodic tick it
  runs `DevIDE.Operator.Risks.detect/1` plus the stateful
  `DevIDE.Operator.Detectors` rules, diffs against the active-risk map keyed
  `{id, subject}`, and on transitions broadcasts
  `{:situation_risk, :raised | :cleared, risk}` on `"situation:<ws>"` and
  emits `operator.risk_raised` / `operator.risk_cleared` audit rows.
  """

  use GenServer
  require Logger

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Operator.Detectors
  alias DevIDE.Operator.Risks
  alias DevIDE.Operator.SituationDigest
  alias DevIDE.Runtimes.WorktreeAlarm
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Terminals.SessionEvents
  alias DevIDE.Terminals.TmuxTopology

  @registry DevIDE.Operator.Registry
  @supervisor DevIDE.Operator.SituationSupervisor
  @pubsub DevIDE.PubSub
  @topic_prefix "situation:"

  # Trailing-edge debounce for full rebuilds (topology-shaped changes) and
  # detector runs (cheap in-place changes). Bursts collapse to one pass.
  @rebuild_debounce_ms 250
  @detect_debounce_ms 250

  # Matches SituationDigest.@recent_activity — the in-place activity tail
  # keeps the same cap as a cold build.
  @recent_activity 20

  defstruct [
    :workspace_id,
    # Latest digest (SituationDigest shape, risks = active risk list) or nil
    # while the first build hasn't succeeded yet.
    :digest,
    :rebuild_timer,
    :detect_timer,
    # Per-sid output freshness from SessionEvents: monotonic content gen and
    # the time we last saw (or started watching for) output.
    last_output_gen: %{},
    last_output_at: %{},
    # Subscription bookkeeping, re-synced to the digest on every full rebuild.
    session_sids: MapSet.new(),
    topology_sessions: MapSet.new(),
    # %{{tmux_session, pane_id} => AgentState.entry()} — reported_at feeds
    # :blocked_too_long.
    agent_entries: %{},
    # Active risks keyed {id, subject}; transitions broadcast + audit.
    active_risks: %{},
    # Cached WorktreeAlarm sweep (refreshed at most once per interval, off
    # the server process).
    worktree_alarms: [],
    worktree_swept_at_ms: nil,
    worktree_sweep_ref: nil
  ]

  ## Public API

  @doc "Whether the live situation server is enabled (`DEV_IDE_SITUATION_SERVER`)."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:dev_ide, :situation_server, false)

  @doc """
  The workspace's situation digest.

  With the flag on this starts the server on demand and serves the live
  digest; with the flag off — or whenever the server can't be reached — it
  falls back to the Phase-0 cold `SituationDigest.build/1`, so callers never
  regress.
  """
  @spec get_digest(String.t()) :: {:ok, map()} | {:error, term()}
  def get_digest(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    with true <- enabled?(),
         {:ok, pid} <- ensure_started(workspace_id) do
      GenServer.call(pid, :get_digest, 10_000)
    else
      _ -> SituationDigest.build(workspace_id)
    end
  catch
    :exit, _ -> SituationDigest.build(workspace_id)
  end

  def get_digest(workspace_id), do: SituationDigest.build(workspace_id)

  @doc """
  The active risks of a running server, whereis-safe: `[]` when no server is
  running (never starts one — read-only surfaces reflect, they don't spawn).
  """
  @spec active_risks(String.t()) :: [map()]
  def active_risks(workspace_id) when is_binary(workspace_id) do
    case whereis(workspace_id) do
      nil -> []
      pid -> GenServer.call(pid, :active_risks, 5_000)
    end
  catch
    :exit, _ -> []
  end

  @doc "PubSub topic carrying `{:situation_risk, :raised | :cleared, risk}`."
  @spec topic(String.t()) :: String.t()
  def topic(workspace_id) when is_binary(workspace_id), do: @topic_prefix <> workspace_id

  @spec subscribe(String.t()) :: :ok | {:error, term()}
  def subscribe(workspace_id) when is_binary(workspace_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(workspace_id))
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, key(workspace_id)) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(workspace_id) when is_binary(workspace_id) do
    case whereis(workspace_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        case DynamicSupervisor.start_child(@supervisor, {__MODULE__, workspace_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def start_link(workspace_id) when is_binary(workspace_id) do
    GenServer.start_link(__MODULE__, workspace_id,
      name: {:via, Registry, {@registry, key(workspace_id)}}
    )
  end

  def child_spec(workspace_id) do
    %{
      id: {__MODULE__, workspace_id},
      start: {__MODULE__, :start_link, [workspace_id]},
      restart: :temporary
    }
  end

  defp key(workspace_id), do: {:situation_server, workspace_id}

  ## GenServer

  @impl true
  def init(workspace_id) do
    # Workspace-wide topics up front; per-session topics (SessionEvents,
    # topology) sync after each full rebuild since they follow the digest.
    :ok = Phoenix.PubSub.subscribe(@pubsub, AgentState.topic(workspace_id))
    :ok = Activity.subscribe(workspace_id)
    :ok = Audit.subscribe(workspace_id)
    :ok = Phoenix.PubSub.subscribe(@pubsub, "deploy:updates")
    :ok = Phoenix.PubSub.subscribe(@pubsub, SessionDirectory.topic(workspace_id))

    schedule_tick()

    {:ok, %__MODULE__{workspace_id: workspace_id}, {:continue, :rebuild}}
  end

  @impl true
  def handle_continue(:rebuild, state), do: {:noreply, rebuild(state)}

  @impl true
  def handle_call(:get_digest, _from, state) do
    # A failed initial build retries inline so a transient constituent error
    # doesn't pin the server on nil forever.
    state = if state.digest, do: state, else: rebuild(state)

    case state.digest do
      nil -> {:reply, {:error, :digest_unavailable}, state}
      digest -> {:reply, {:ok, digest}, state}
    end
  end

  def handle_call(:active_risks, _from, state) do
    {:reply, Map.values(state.active_risks), state}
  end

  @impl true
  # SessionEvents output: bump the sid's content generation + freshness.
  # Cheap — no rebuild; a detector pass may clear :working_no_output.
  def handle_info({:terminal_session_event, %{type: :output, sid: sid, gen: gen}}, state) do
    state = %{
      state
      | last_output_gen: Map.put(state.last_output_gen, sid, gen),
        last_output_at: Map.put(state.last_output_at, sid, DateTime.utc_now())
    }

    {:noreply, schedule_detect(state)}
  end

  # Recovery notices (session recreated, reseed, ...) reshape content — treat
  # like a structural change.
  def handle_info({:terminal_session_event, _notice}, state) do
    {:noreply, schedule_rebuild(state)}
  end

  # Semantic pane-state report: patch the digest pane in place and remember
  # the entry (reported_at feeds :blocked_too_long).
  def handle_info({:agent_state_updated, tmux_session, pane_id, entry}, state) do
    state = %{
      state
      | agent_entries: Map.put(state.agent_entries, {tmux_session, pane_id}, entry),
        digest: patch_pane_state(state.digest, tmux_session, pane_id, entry)
    }

    {:noreply, schedule_detect(state)}
  end

  # MCP tool-call tail: prepend in place with the digest's own mapping and cap.
  def handle_info({:agent_mcp_activity, entry}, state) do
    {:noreply, %{state | digest: patch_activity(state.digest, entry)}}
  end

  # Live audit event: refresh activity.last_mutation. Our own operator.*
  # transition rows update it too but never schedule another pass (detection
  # is transition-diffed, so re-running on our own output is pure churn).
  def handle_info({:audit_event, event}, state) do
    state = %{state | digest: patch_last_mutation(state.digest, event)}

    if is_binary(event.action) and String.starts_with?(event.action, "operator.") do
      {:noreply, state}
    else
      {:noreply, schedule_detect(state)}
    end
  end

  def handle_info({deploy_msg, _info}, state)
      when deploy_msg in [:deploy_drift, :deploy_in_progress, :deploy_failure] do
    {:noreply, state |> refresh_deploy() |> schedule_detect()}
  end

  def handle_info(:deploy_poller_clear, state) do
    {:noreply, state |> refresh_deploy() |> schedule_detect()}
  end

  # Topology-shaped changes (windows/panes appeared or died, session list
  # changed): debounce a full section rebuild.
  def handle_info({TmuxTopology, _msg}, state), do: {:noreply, schedule_rebuild(state)}

  def handle_info({SessionDirectory, {:sessions_updated, _ws, _tabs}}, state) do
    {:noreply, schedule_rebuild(state)}
  end

  def handle_info(:rebuild, state), do: {:noreply, rebuild(%{state | rebuild_timer: nil})}

  def handle_info(:detect, state), do: {:noreply, run_detectors(%{state | detect_timer: nil})}

  def handle_info(:tick, state) do
    schedule_tick()
    {:noreply, run_detectors(state)}
  end

  # Async worktree sweep result (see maybe_start_worktree_sweep/1).
  def handle_info({:worktree_alarms, alarms}, state) when is_list(alarms) do
    state = %{state | worktree_alarms: alarms}
    {:noreply, schedule_detect(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{worktree_sweep_ref: ref} = state) do
    if reason != :normal do
      Logger.warning("[situation] worktree sweep failed: #{inspect(reason)}")
    end

    {:noreply, %{state | worktree_sweep_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Full rebuild

  defp rebuild(state) do
    case SituationDigest.build(state.workspace_id) do
      {:ok, digest} ->
        %{state | digest: digest}
        |> sync_session_subscriptions(digest)
        |> sync_topology_subscriptions(digest)
        |> seed_agent_entries(digest)
        |> run_detectors()

      {:error, reason} ->
        Logger.warning(
          "[situation] digest rebuild failed ws=#{state.workspace_id}: #{inspect(reason)}"
        )

        state
    end
  end

  # Follow the digest's session list: subscribe new sids to the SessionEvents
  # bus (seeding their output baseline at subscribe time — :working_no_output
  # needs a reference even before the first event), drop gone ones.
  defp sync_session_subscriptions(state, digest) do
    ws = state.workspace_id
    sids = digest |> Map.get(:sessions, []) |> collect(:sid)

    for sid <- MapSet.difference(sids, state.session_sids) do
      _ = SessionEvents.subscribe(ws, sid)
    end

    for sid <- MapSet.difference(state.session_sids, sids) do
      Phoenix.PubSub.unsubscribe(@pubsub, SessionEvents.topic(ws, sid))
    end

    now = DateTime.utc_now()

    last_output_at =
      Map.new(sids, fn sid -> {sid, Map.get(state.last_output_at, sid, now)} end)

    %{
      state
      | session_sids: sids,
        last_output_at: last_output_at,
        last_output_gen: Map.take(state.last_output_gen, MapSet.to_list(sids))
    }
  end

  # Passive topology awareness: subscribe to the watcher topics of the
  # digest's tmux sessions. No watcher is started here — when viewers (or
  # other consumers) run one, its change events reach us for free.
  defp sync_topology_subscriptions(state, digest) do
    sessions = digest |> Map.get(:sessions, []) |> collect(:tmux_session)

    for session <- MapSet.difference(sessions, state.topology_sessions) do
      Phoenix.PubSub.subscribe(@pubsub, TmuxTopology.topic(session))
    end

    for session <- MapSet.difference(state.topology_sessions, sessions) do
      Phoenix.PubSub.unsubscribe(@pubsub, TmuxTopology.topic(session))
    end

    %{state | topology_sessions: sessions}
  end

  # Re-seed the agent-state observation map from the live read model so
  # reported_at survives server restarts and pre-subscription reports count.
  defp seed_agent_entries(state, digest) do
    entries =
      for session <- Map.get(digest, :sessions, []),
          tmux_session = Map.get(session, :tmux_session),
          is_binary(tmux_session),
          {pane_id, entry} <- agent_reports(tmux_session),
          into: %{} do
        {{tmux_session, pane_id}, entry}
      end

    %{state | agent_entries: entries}
  end

  defp agent_reports(tmux_session) do
    AgentState.for_session(tmux_session)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp collect(sessions, field) do
    sessions
    |> Enum.map(&Map.get(&1, field))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> MapSet.new()
  end

  ## Detector engine

  defp run_detectors(%{digest: nil} = state), do: state

  defp run_detectors(state) do
    now = DateTime.utc_now()
    state = maybe_start_worktree_sweep(state)

    risks =
      Risks.detect(state.digest) ++
        Detectors.blocked_too_long(state.agent_entries, now, blocked_threshold_s()) ++
        Detectors.working_no_output(state.digest, state.last_output_at, now, output_threshold_s()) ++
        Detectors.leaked_worktree(state.worktree_alarms, state.workspace_id, now)

    next_active = Map.new(risks, fn risk -> {{risk.id, risk.subject}, risk} end)

    for {key, risk} <- next_active, not Map.has_key?(state.active_risks, key) do
      announce(state.workspace_id, :raised, risk)
    end

    for {key, risk} <- state.active_risks, not Map.has_key?(next_active, key) do
      announce(state.workspace_id, :cleared, risk)
    end

    %{state | active_risks: next_active, digest: %{state.digest | risks: Map.values(next_active)}}
  end

  # Transition-only fan-out: audit row for the durable timeline first, then
  # the broadcast for live UIs — subscribers reacting to the message can rely
  # on the row existing. Risk free text is already redacted (digest and
  # detectors sanitize at the edges).
  defp announce(workspace_id, kind, risk) do
    _ =
      Audit.emit!(%{
        workspace_id: workspace_id,
        actor_id: "situation_server",
        action: "operator.risk_#{kind}",
        source: "operator",
        target_type: "risk",
        target_ref: risk.subject || to_string(risk.id),
        metadata: %{
          id: risk.id,
          severity: risk.severity,
          subject: risk.subject,
          evidence: risk.evidence,
          suggestion: risk.suggestion
        }
      })

    Phoenix.PubSub.broadcast(@pubsub, topic(workspace_id), {:situation_risk, kind, risk})

    :ok
  end

  # WorktreeAlarm.sweep_now walks worktree roots with git reads — too slow
  # for the server loop, so it runs in a monitored helper process at most
  # once per interval (rate-limited from sweep *start*, so a crash can't
  # tight-loop it). emit: false — the alarm's own audit trail stays with the
  # janitor path; we only want candidates.
  defp maybe_start_worktree_sweep(state) do
    now_ms = System.monotonic_time(:millisecond)

    fresh? =
      is_integer(state.worktree_swept_at_ms) and
        now_ms - state.worktree_swept_at_ms < sweep_interval_ms()

    if state.worktree_sweep_ref != nil or fresh? do
      state
    else
      parent = self()

      {_pid, ref} =
        spawn_monitor(fn ->
          send(parent, {:worktree_alarms, WorktreeAlarm.sweep_now(emit: false).alarms})
        end)

      %{state | worktree_sweep_ref: ref, worktree_swept_at_ms: now_ms}
    end
  end

  ## Incremental digest patches (cheap, no re-dating — see moduledoc)

  defp patch_pane_state(nil, _tmux_session, _pane_id, _entry), do: nil

  defp patch_pane_state(digest, tmux_session, pane_id, entry) do
    Map.update!(digest, :sessions, fn sessions ->
      Enum.map(sessions, fn session ->
        if Map.get(session, :tmux_session) == tmux_session do
          Map.update(session, :panes, [], &patch_panes(&1, pane_id, entry))
        else
          session
        end
      end)
    end)
  end

  defp patch_panes(panes, pane_id, entry) do
    Enum.map(panes, fn pane ->
      if Map.get(pane, :id) == pane_id do
        pane
        |> Map.put(:agent_state, Map.get(entry, :state))
        |> put_present(:agent_state_message, sanitize(Map.get(entry, :message)))
        |> Map.put(:agent_state_age_s, 0)
      else
        pane
      end
    end)
  end

  defp patch_activity(nil, _entry), do: nil

  defp patch_activity(digest, entry) do
    mapped =
      compact(%{
        tool: Map.get(entry, :tool),
        source: Map.get(entry, :source),
        summary: sanitize(Map.get(entry, :summary)),
        status: Map.get(entry, :status),
        at: Map.get(entry, :inserted_at)
      })

    digest
    |> update_in([:activity, :recent], &Enum.take([mapped | &1 || []], @recent_activity))
    |> put_in([:freshness, :activity], 0)
  end

  defp patch_last_mutation(nil, _event), do: nil

  defp patch_last_mutation(digest, event) do
    mutation =
      compact(%{
        action: event.action,
        target_type: event.target_type,
        target_ref: event.target_ref,
        actor_id: event.actor_id,
        at: event.inserted_at
      })

    put_in(digest, [:activity, :last_mutation], mutation)
  end

  defp refresh_deploy(%{digest: nil} = state), do: state

  defp refresh_deploy(state) do
    %{state | digest: Map.put(state.digest, :deploy, SituationDigest.deploy_section())}
  end

  ## Debounce + timers

  defp schedule_rebuild(%{rebuild_timer: nil} = state) do
    %{state | rebuild_timer: Process.send_after(self(), :rebuild, @rebuild_debounce_ms)}
  end

  defp schedule_rebuild(state), do: state

  # A pending rebuild already ends in a detector pass; don't double up.
  defp schedule_detect(%{rebuild_timer: timer} = state) when timer != nil, do: state

  defp schedule_detect(%{detect_timer: nil} = state) do
    %{state | detect_timer: Process.send_after(self(), :detect, @detect_debounce_ms)}
  end

  defp schedule_detect(state), do: state

  defp schedule_tick, do: Process.send_after(self(), :tick, tick_ms())

  ## Config + small helpers

  defp blocked_threshold_s,
    do: Application.get_env(:dev_ide, :situation_blocked_too_long_seconds, 600)

  defp output_threshold_s,
    do: Application.get_env(:dev_ide, :situation_working_no_output_seconds, 300)

  defp tick_ms, do: Application.get_env(:dev_ide, :situation_tick_ms, 60_000)

  defp sweep_interval_ms, do: Application.get_env(:dev_ide, :situation_worktree_sweep_ms, 60_000)

  defp sanitize(text) when is_binary(text), do: Sanitizer.redact_text(text)
  defp sanitize(_text), do: nil

  defp put_present(map, key, nil), do: Map.delete(map, key)
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
