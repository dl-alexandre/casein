defmodule Casein.Terminals.AgentStateTest do
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentEvents
  alias Casein.Terminals.AgentState

  setup do
    AgentState.clear()
    AgentEvents.clear()

    on_exit(fn ->
      AgentState.clear()
      AgentEvents.clear()
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

      # Casts are async — a call serializes before asserting eviction.
      assert AgentState.get("casein_evict", "%0") == nil

      # The eviction tombstone remembers the last state: this re-report is not
      # a transition, so no new agent.state_changed row for the probe pane.
      :ok = AgentState.report("ws-evict-probe", "casein_evict", "%0", :working, "step")
      assert %{state: :working} = AgentState.get("casein_evict", "%0")

      actions =
        "ws-evict-probe" |> Casein.Audit.recent_for(10) |> Enum.map(& &1.action)

      assert actions == ["agent.state_changed"]
    end

    test "a pruned pane re-reporting an unchanged state adds no timeline row" do
      :ok = AgentState.report("ws-prune-probe", "casein_prune", "%1", :working, "step")
      :ok = AgentState.prune_session("casein_prune", [])
      assert AgentState.get("casein_prune", "%1") == nil

      :ok = AgentState.report("ws-prune-probe", "casein_prune", "%1", :working, "step")
      assert %{state: :working} = AgentState.get("casein_prune", "%1")

      actions =
        "ws-prune-probe" |> Casein.Audit.recent_for(10) |> Enum.map(& &1.action)

      assert actions == ["agent.state_changed"]
    end

    test "a real transition across an eviction still records from/to" do
      :ok = AgentState.report("ws-evict-flip", "casein_evict2", "%0", :working, "step")

      for i <- 1..501 do
        :ok = AgentState.report("ws-evict-fill2", "casein_evict_fill2", "%#{i}", :working, "f")
      end

      assert AgentState.get("casein_evict2", "%0") == nil

      :ok = AgentState.report("ws-evict-flip", "casein_evict2", "%0", :blocked, "stuck")
      assert %{state: :blocked} = AgentState.get("casein_evict2", "%0")

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
