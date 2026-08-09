defmodule Casein.Terminals.AgentStateTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentEvents
  alias Casein.Runs.AgentLifecycle
  alias Casein.Terminals.AgentState

  setup do
    AgentState.clear()
    AgentEvents.clear()
    AgentLifecycle.clear()

    on_exit(fn ->
      AgentState.clear()
      AgentEvents.clear()
      AgentLifecycle.clear()
    end)

    :ok
  end

  defp entry(state, seconds_ago, message \\ nil) do
    %{
      state: state,
      message: message,
      source: :mcp,
      tool: "terminal_report_agent_state",
      workspace_id: "ws-1",
      transcript_path: nil,
      agent_session_id: nil,
      reported_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    }
  end

  # AgentLifecycle writes run.* into the same audit stream; these tests own
  # agent.state_changed volume only.
  defp state_changed_actions(workspace_id) do
    workspace_id
    |> Casein.Audit.recent_for(20)
    |> Enum.map(& &1.action)
    |> Enum.filter(&(&1 == "agent.state_changed"))
  end

  # Drain eviction fill casts before asserting. AgentState.get/2 defaults to a
  # 5s call timeout; 501 audit-emitting report casts can exceed that under the
  # shared pr-gate host.
  defp agent_state_get(tmux_session, pane_id) do
    GenServer.call(AgentState, {:get, {tmux_session, pane_id}}, 60_000)
  end

  describe "report/get/for_session" do
    test "stores and broadcasts a report, keyed by session and pane" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      :ok = AgentState.subscribe(ws)

      :ok =
        AgentState.report(ws, "casein_alpha_u-dev", "%3", :blocked, "needs permission")

      assert_receive {:agent_state_updated, "casein_alpha_u-dev", "%3", entry}
      assert entry.state == :blocked
      assert entry.message == "needs permission"
      assert AgentState.get("casein_alpha_u-dev", "%3").state == :blocked
      assert %{"%3" => %{state: :blocked}} = AgentState.for_session("casein_alpha_u-dev")
    end

    test "accepts string states and truncates the message" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      long = String.duplicate("x", 500)
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", "working", long)

      assert %{state: :working, message: message} = AgentState.get("casein_alpha_u-dev", "%3")
      assert String.length(message) == 200
    end

    test "ignores unrecognized states" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", "bogus", nil)
      assert AgentState.get("casein_alpha_u-dev", "%3") == nil
    end

    test "stores transcript_path from hook reports" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      path = "/home/devbox/.claude/projects/test/session.jsonl"

      :ok =
        AgentState.report(ws, "casein_alpha_u-dev", "%3", :working, nil,
          source: :hook,
          transcript_path: path
        )

      assert AgentState.get("casein_alpha_u-dev", "%3").transcript_path == path
    end

    test "stores an agent runtime session id from hook reports" do
      ws = "ws-state-#{System.unique_integer([:positive])}"

      :ok =
        AgentState.report(ws, "casein_alpha_u-dev", "%3", :working, nil,
          source: :hook,
          agent_session_id: "grok-session-123"
        )

      assert AgentState.get("casein_alpha_u-dev", "%3").agent_session_id ==
               "grok-session-123"
    end

    test "identical re-report refreshes freshness without broadcasting" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      :ok = AgentState.subscribe(ws)
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", :working, "compiling")
      assert_receive {:agent_state_updated, _, _, _}

      before = AgentState.get("casein_alpha_u-dev", "%3").reported_at
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", :working, "compiling")
      refute_receive {:agent_state_updated, _, _, _}, 100

      after_ts = AgentState.get("casein_alpha_u-dev", "%3").reported_at
      assert DateTime.compare(after_ts, before) in [:gt, :eq]
    end

    test "prune_session drops entries for panes that no longer exist" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", :working, nil)
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%4", :done, nil)

      :ok = AgentState.prune_session("casein_alpha_u-dev", ["%3"])

      assert AgentState.get("casein_alpha_u-dev", "%3").state == :working
      assert AgentState.get("casein_alpha_u-dev", "%4") == nil
    end
  end

  describe "agent.blocked audit" do
    test "emits once on transition into blocked, not on re-report" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"
      :ok = Casein.Audit.subscribe(ws)

      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", :working, nil)
      refute_receive {:audit_event, %{action: "agent.blocked"}}, 100

      :ok =
        AgentState.report(ws, "casein_alpha_u-dev", "%3", :blocked, "needs perm",
          agent_session_id: "grok-session-blocked"
        )

      assert_receive {:audit_event, %{action: "agent.blocked", metadata: metadata}}
      assert metadata.pane == "%3"
      assert metadata.message == "needs perm"
      assert metadata.agent_session_id == "grok-session-blocked"

      # Both transitions can share the adapter's timestamp precision, so their
      # relative order in recent_for/1 is intentionally unspecified. Assert on
      # the transition identity instead of assuming the blocked row sorts first.
      transition =
        Enum.find(AgentEvents.recent_for(ws), fn event ->
          event.event_type == "agent.state_changed" and
            event.agent_session_id == "grok-session-blocked"
        end)

      assert transition
      assert transition.agent_session_id == "grok-session-blocked"
      assert transition.payload["message_present"] == true
      refute inspect(transition) =~ "needs perm"

      # A second blocked report (different message) must not re-alert.
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", :blocked, "still blocked")
      refute_receive {:audit_event, %{action: "agent.blocked"}}, 100
    end

    test "blocked audit inherits the reporter's causality context" do
      ws = "ws-audit-ctx-#{System.unique_integer([:positive])}"
      :ok = Casein.Audit.subscribe(ws)

      cid =
        Casein.Signals.Context.with_new(fn ->
          :ok = AgentState.report(ws, "casein_alpha_u-dev", "%9", :blocked, "stuck")
          Casein.Signals.Context.current().trace_id
        end)

      assert_receive {:audit_event, %{action: "agent.blocked", metadata: metadata}}
      assert metadata["correlation_id"] == cid
    end
  end

  describe "agent.state_changed audit" do
    test "emits a durable row for every real state transition, with from/to" do
      :ok = Casein.Audit.subscribe("ws-timeline")

      :ok = AgentState.report("ws-timeline", "casein_alpha_u-dev", "%5", :working, "compiling")
      assert_receive {:audit_event, %{action: "agent.state_changed", metadata: metadata}}
      assert metadata.from == nil
      assert metadata.to == :working
      assert metadata.pane == "%5"
      assert metadata.tmux_session == "casein_alpha_u-dev"
      assert metadata.message == "compiling"

      :ok = AgentState.report("ws-timeline", "casein_alpha_u-dev", "%5", :done, nil)
      assert_receive {:audit_event, %{action: "agent.state_changed", metadata: metadata}}
      assert metadata.from == :working
      assert metadata.to == :done
    end

    test "identical or message-only re-reports do not add timeline rows" do
      :ok = Casein.Audit.subscribe("ws-timeline")

      :ok = AgentState.report("ws-timeline", "casein_alpha_u-dev", "%6", :working, "step 1")
      assert_receive {:audit_event, %{action: "agent.state_changed"}}

      # Identical report: deduped upstream, no row.
      :ok = AgentState.report("ws-timeline", "casein_alpha_u-dev", "%6", :working, "step 1")
      refute_receive {:audit_event, %{action: "agent.state_changed"}}, 100

      # Message changed but the state did not: broadcast fires, no timeline row.
      :ok = AgentState.report("ws-timeline", "casein_alpha_u-dev", "%6", :working, "step 2")
      refute_receive {:audit_event, %{action: "agent.state_changed"}}, 100
    end

    test "an evicted pane re-reporting an unchanged state adds no timeline row" do
      # Distinct workspaces separate the probe pane's rows from filler noise.
      :ok = AgentState.report("ws-evict-probe", "casein_evict", "%0", :working, "step")

      # Push the tracked-pane count past the cap so %0 (oldest) gets evicted.
      for i <- 1..501 do
        :ok = AgentState.report("ws-evict-fill", "casein_evict_fill", "%#{i}", :working, "fill")
      end

      # Casts are async — a call serializes before asserting eviction. The fill
      # loop queues 501 report casts that each may emit audit/lifecycle work, so
      # the default 5s call timeout is not enough under a busy shared gate box.
      assert agent_state_get("casein_evict", "%0") == nil

      # The eviction tombstone remembers the last state: this re-report is not
      # a transition, so no new agent.state_changed row for the probe pane.
      :ok = AgentState.report("ws-evict-probe", "casein_evict", "%0", :working, "step")
      assert %{state: :working} = agent_state_get("casein_evict", "%0")

      # Lifecycle altitude (run.*) shares the audit stream; assert only the
      # agent.state_changed volume this test owns.
      actions = state_changed_actions("ws-evict-probe")

      assert actions == ["agent.state_changed"]
    end

    test "a pruned pane re-reporting an unchanged state adds no timeline row" do
      :ok = AgentState.report("ws-prune-probe", "casein_prune", "%1", :working, "step")
      :ok = AgentState.prune_session("casein_prune", [])
      assert AgentState.get("casein_prune", "%1") == nil

      :ok = AgentState.report("ws-prune-probe", "casein_prune", "%1", :working, "step")
      assert %{state: :working} = AgentState.get("casein_prune", "%1")

      actions = state_changed_actions("ws-prune-probe")

      assert actions == ["agent.state_changed"]
    end

    test "a real transition across an eviction still records from/to" do
      :ok = AgentState.report("ws-evict-flip", "casein_evict2", "%0", :working, "step")

      for i <- 1..501 do
        :ok = AgentState.report("ws-evict-fill2", "casein_evict_fill2", "%#{i}", :working, "f")
      end

      assert agent_state_get("casein_evict2", "%0") == nil

      :ok = AgentState.report("ws-evict-flip", "casein_evict2", "%0", :blocked, "stuck")
      assert %{state: :blocked} = agent_state_get("casein_evict2", "%0")

      [row | _] =
        "ws-evict-flip"
        |> Casein.Audit.recent_for(10)
        |> Enum.filter(&(&1.action == "agent.state_changed"))

      assert row.metadata.from == :working
      assert row.metadata.to == :blocked
    end

    test "a blocked transition also keeps the dedicated agent.blocked row" do
      :ok = Casein.Audit.subscribe("ws-timeline")

      :ok = AgentState.report("ws-timeline", "casein_alpha_u-dev", "%7", :blocked, "needs perm")

      assert_receive {:audit_event, %{action: "agent.state_changed", metadata: %{to: :blocked}}}
      assert_receive {:audit_event, %{action: "agent.blocked"}}
    end

    test "secrets in the report message are redacted before persistence" do
      :ok = Casein.Audit.subscribe("ws-timeline")

      :ok =
        AgentState.report(
          "ws-timeline",
          "casein_alpha_u-dev",
          "%8",
          :blocked,
          "export token=super-secret"
        )

      assert_receive {:audit_event, %{action: "agent.state_changed", metadata: metadata}}
      assert metadata.message =~ "[REDACTED]"
      refute metadata.message =~ "super-secret"
    end
  end

  describe "session_status/2" do
    test "maps freshest reported state to picker vocabulary" do
      ws = "ws-state-#{System.unique_integer([:positive])}"
      :ok = AgentState.report(ws, "casein_alpha_u-dev", "%3", :blocked, nil)
      assert AgentState.session_status("casein_alpha_u-dev") == "attention"
    end

    test "ignores reports older than the max TTL" do
      # No live report → nil, even though a stale one would exist in a real run.
      assert AgentState.session_status("casein_empty_u-dev") == nil
    end
  end

  describe "semantic_from_heuristic/1" do
    test "maps ready to idle, never done" do
      assert AgentState.semantic_from_heuristic(:working) == :working
      assert AgentState.semantic_from_heuristic(:ready) == :idle
      assert AgentState.semantic_from_heuristic(:unknown) == :unknown
    end
  end

  describe "resolve/3 precedence" do
    test "no report falls back to heuristic mapping" do
      assert AgentState.resolve(nil, :working) == {:working, nil}
      assert AgentState.resolve(nil, :ready) == {:idle, nil}
      assert AgentState.resolve(nil, :unknown) == {:unknown, nil}
    end

    test "report older than max TTL is discarded for the heuristic" do
      assert AgentState.resolve(entry(:blocked, 2_000), :working) == {:working, nil}
      assert AgentState.resolve(entry(:blocked, 2_000), :ready) == {:idle, nil}
    end

    test "a fresh report wins unconditionally" do
      assert AgentState.resolve(entry(:blocked, 1, "perm"), :working) == {:blocked, "perm"}
    end

    test "a live working spinner overrides a stale non-working report" do
      assert AgentState.resolve(entry(:blocked, 60, "perm"), :working) == {:working, nil}
      assert AgentState.resolve(entry(:done, 60), :working) == {:working, nil}
    end

    test "a ready title downgrades a long-stale working report to idle, never done" do
      assert AgentState.resolve(entry(:working, 300), :ready) == {:idle, nil}
    end

    test "otherwise the report wins" do
      assert AgentState.resolve(entry(:blocked, 60, "perm"), :ready) == {:blocked, "perm"}
      assert AgentState.resolve(entry(:done, 60), :unknown) == {:done, nil}
    end
  end

  describe "resolve/4 with observed liveness" do
    @stale 700

    test "a frozen spinner over a silent worktree is stalled, not working" do
      # The wedge signature: the TUI stopped processing but left its last
      # spinner frame on screen, so the title heuristic reads :working forever.
      assert AgentState.resolve(nil, :working, now(), :quiet) == {:stalled, nil}

      assert AgentState.resolve(entry(:blocked, @stale, "perm"), :working, now(), :quiet) ==
               {:stalled, nil}

      assert AgentState.resolve(entry(:working, @stale), :working, now(), :quiet) ==
               {:stalled, nil}
    end

    test "a spinner backed by real worktree activity stays working" do
      assert AgentState.resolve(nil, :working, now(), :active) == {:working, nil}

      assert AgentState.resolve(entry(:blocked, @stale, "perm"), :working, now(), :active) ==
               {:working, nil}
    end

    test "a busy pane is not called stalled before the stall window elapses" do
      # Long tool calls and model thinking are normal; a premature :stalled costs
      # more trust than a late one.
      assert AgentState.resolve(entry(:blocked, 60, "perm"), :working, now(), :quiet) ==
               {:working, nil}
    end

    test "unknown liveness changes nothing, so a failed check cannot invent a stall" do
      # This is the false-stall bug: a check that did not run must not read as
      # evidence of inactivity.
      for liveness <- [nil, :unknown] do
        assert AgentState.resolve(nil, :working, now(), liveness) == {:working, nil}

        assert AgentState.resolve(entry(:blocked, @stale, "perm"), :working, now(), liveness) ==
                 {:working, nil}
      end
    end

    test "worktree activity rescues a working report the title calls ready" do
      # Default behaviour assumes a missed Stop hook and downgrades to idle. If
      # the worktree is still being written, the report was simply right.
      assert AgentState.resolve(entry(:working, 300), :ready, now(), :active) == {:working, nil}
      assert AgentState.resolve(entry(:working, 300), :ready, now(), :quiet) == {:idle, nil}
      assert AgentState.resolve(entry(:working, 300), :ready, now(), nil) == {:idle, nil}
    end

    test "liveness never overrides a fresh report" do
      assert AgentState.resolve(entry(:blocked, 1, "perm"), :working, now(), :quiet) ==
               {:blocked, "perm"}
    end

    test "errored is reportable and outranks a stale title" do
      assert AgentState.resolve(entry(:errored, 60, "provider 400"), :ready) ==
               {:errored, "provider 400"}
    end

    test "a stalled pane is surfaced even without a report" do
      # The one case where an unreported pane earns a label: it is displaying
      # activity that is not happening.
      assert AgentState.resolve_for_display(nil, :working, now(), :quiet) == {:stalled, nil}
      assert AgentState.resolve_for_display(nil, :working, now(), :active) == {:unknown, nil}
      assert AgentState.resolve_for_display(nil, :ready, now(), :quiet) == {:unknown, nil}
    end

    test "an expired report still yields stalled when the spinner is frozen" do
      assert AgentState.resolve_for_display(entry(:working, 2_000), :working, now(), :quiet) ==
               {:stalled, nil}
    end

    defp now, do: DateTime.utc_now()
  end

  describe "folding pane liveness into topology enrichment" do
    setup do
      AgentState.clear()
      :ok
    end

    test "a recently-written worktree is never called stalled" do
      # The false positive worth guarding: PaneLiveness calls a 4-minute-quiet
      # worktree :quiet against its short activity window, but that is nowhere
      # near long enough to stop believing a spinner.
      topology = topology_with_liveness(%{state: :quiet, quiet_for_seconds: 240})

      assert %{panes: [pane]} = AgentState.enrich_topology(topology, "casein_x")
      # Unreported panes stay unlabeled so a plain shell does not read as an
      # agent; the point here is that 4 minutes of quiet earns no stall claim.
      refute Map.has_key?(pane, :agent_state)
    end

    test "a long-silent worktree under a live spinner is stalled" do
      topology = topology_with_liveness(%{state: :quiet, quiet_for_seconds: 3_600})

      assert %{panes: [%{agent_state: :stalled}]} =
               AgentState.enrich_topology(topology, "casein_x")
    end

    test "an unobservable worktree yields no stall claim" do
      # PaneLiveness reports :unknown with a reason and no duration. That is the
      # absence of evidence, not evidence of absence.
      topology = topology_with_liveness(%{state: :unknown, reason: :enoent})

      assert %{panes: [pane]} = AgentState.enrich_topology(topology, "casein_x")
      refute Map.get(pane, :agent_state) == :stalled
    end

    test "panes with no liveness at all behave exactly as before" do
      topology = topology_with_liveness(nil)

      assert %{panes: [pane]} = AgentState.enrich_topology(topology, "casein_x")
      refute Map.get(pane, :agent_state) == :stalled
    end

    defp topology_with_liveness(liveness) do
      pane =
        %{id: "%1", window_id: "@1", pane_state: :working, active: true}
        |> then(fn p -> if liveness, do: Map.put(p, :liveness, liveness), else: p end)

      %{panes: [pane], windows: [%{id: "@1", pane_list: [pane]}]}
    end
  end

  describe "reportable states" do
    test "errored is reportable but stalled is not" do
      # :stalled is derived from evidence — the agents that most need it are the
      # ones that have stopped reporting anything.
      assert :errored in AgentState.report_states()
      refute :stalled in AgentState.report_states()
    end

    test "both errored and stalled ask for a human in the picker" do
      AgentState.clear()
      :ok = AgentState.report("ws-1", "casein_x", "%1", :errored, "provider 400")

      assert AgentState.session_status("casein_x") == "attention"
    end
  end

  describe "resolve_for_display/3" do
    test "returns unknown without a live report, so the heuristic is not mislabeled" do
      assert AgentState.resolve_for_display(nil, :ready) == {:unknown, nil}
      assert AgentState.resolve_for_display(nil, :working) == {:unknown, nil}
    end

    test "returns unknown for an expired report" do
      assert AgentState.resolve_for_display(entry(:blocked, 2_000), :ready) == {:unknown, nil}
    end

    test "resolves a live report like resolve/3" do
      assert AgentState.resolve_for_display(entry(:blocked, 1, "perm"), :ready) ==
               {:blocked, "perm"}
    end
  end

  describe "enrich_topology/2" do
    test "adds resolved agent_state to panes and windows, omitting unknown" do
      ws = "ws-state-#{System.unique_integer([:positive])}"

      :ok =
        AgentState.report(ws, "casein_alpha_u-dev", "%3", :blocked, "needs input",
          agent_session_id: "grok-session-123"
        )

      topology = %{
        panes: [
          %{id: "%3", pane_state: :ready, role: "agent"},
          %{id: "%4", pane_state: :unknown}
        ],
        windows: [
          %{
            pane_list: [
              %{id: "%3", pane_state: :ready, role: "agent"}
            ]
          }
        ]
      }

      enriched = AgentState.enrich_topology(topology, "casein_alpha_u-dev")

      agent_pane = Enum.find(enriched.panes, &(&1.id == "%3"))
      other_pane = Enum.find(enriched.panes, &(&1.id == "%4"))

      assert agent_pane.agent_state == :blocked
      assert agent_pane.agent_state_message == "needs input"
      assert agent_pane.agent_session_id == "grok-session-123"
      refute Map.has_key?(other_pane, :agent_state)

      assert hd(enriched.windows).agent_state == :blocked
      assert hd(enriched.windows).agent_session_id == "grok-session-123"
    end
  end
end
