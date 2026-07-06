defmodule DevIDE.Terminals.AgentStateTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Terminals.AgentState

  setup do
    AgentState.clear()
    on_exit(fn -> AgentState.clear() end)
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
      reported_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
    }
  end

  describe "report/get/for_session" do
    test "stores and broadcasts a report, keyed by session and pane" do
      :ok = AgentState.subscribe("ws-state")

      :ok =
        AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :blocked, "needs permission")

      assert_receive {:agent_state_updated, "devide_alpha_u-dev", "%3", entry}
      assert entry.state == :blocked
      assert entry.message == "needs permission"
      assert AgentState.get("devide_alpha_u-dev", "%3").state == :blocked
      assert %{"%3" => %{state: :blocked}} = AgentState.for_session("devide_alpha_u-dev")
    end

    test "accepts string states and truncates the message" do
      long = String.duplicate("x", 500)
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", "working", long)

      assert %{state: :working, message: message} = AgentState.get("devide_alpha_u-dev", "%3")
      assert String.length(message) == 200
    end

    test "ignores unrecognized states" do
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", "bogus", nil)
      assert AgentState.get("devide_alpha_u-dev", "%3") == nil
    end

    test "stores transcript_path from hook reports" do
      path = "/home/devbox/.claude/projects/test/session.jsonl"

      :ok =
        AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :working, nil,
          source: :hook,
          transcript_path: path
        )

      assert AgentState.get("devide_alpha_u-dev", "%3").transcript_path == path
    end

    test "identical re-report refreshes freshness without broadcasting" do
      :ok = AgentState.subscribe("ws-state")
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :working, "compiling")
      assert_receive {:agent_state_updated, _, _, _}

      before = AgentState.get("devide_alpha_u-dev", "%3").reported_at
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :working, "compiling")
      refute_receive {:agent_state_updated, _, _, _}, 100

      after_ts = AgentState.get("devide_alpha_u-dev", "%3").reported_at
      assert DateTime.compare(after_ts, before) in [:gt, :eq]
    end

    test "prune_session drops entries for panes that no longer exist" do
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :working, nil)
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%4", :done, nil)

      :ok = AgentState.prune_session("devide_alpha_u-dev", ["%3"])

      assert AgentState.get("devide_alpha_u-dev", "%3").state == :working
      assert AgentState.get("devide_alpha_u-dev", "%4") == nil
    end
  end

  describe "agent.blocked audit" do
    test "emits once on transition into blocked, not on re-report" do
      :ok = DevIDE.Audit.subscribe("ws-audit")

      :ok = AgentState.report("ws-audit", "devide_alpha_u-dev", "%3", :working, nil)
      refute_receive {:audit_event, %{action: "agent.blocked"}}, 100

      :ok = AgentState.report("ws-audit", "devide_alpha_u-dev", "%3", :blocked, "needs perm")
      assert_receive {:audit_event, %{action: "agent.blocked", metadata: metadata}}
      assert metadata.pane == "%3"
      assert metadata.message == "needs perm"

      # A second blocked report (different message) must not re-alert.
      :ok = AgentState.report("ws-audit", "devide_alpha_u-dev", "%3", :blocked, "still blocked")
      refute_receive {:audit_event, %{action: "agent.blocked"}}, 100
    end

    test "blocked audit inherits the reporter's causality context" do
      :ok = DevIDE.Audit.subscribe("ws-audit-ctx")

      cid =
        DevIDE.Signals.Context.with_new(fn ->
          :ok = AgentState.report("ws-audit-ctx", "devide_alpha_u-dev", "%9", :blocked, "stuck")
          DevIDE.Signals.Context.current().trace_id
        end)

      assert_receive {:audit_event, %{action: "agent.blocked", metadata: metadata}}
      assert metadata["correlation_id"] == cid
    end
  end

  describe "session_status/2" do
    test "maps freshest reported state to picker vocabulary" do
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :blocked, nil)
      assert AgentState.session_status("devide_alpha_u-dev") == "attention"
    end

    test "ignores reports older than the max TTL" do
      # No live report → nil, even though a stale one would exist in a real run.
      assert AgentState.session_status("devide_empty_u-dev") == nil
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
      :ok = AgentState.report("ws-state", "devide_alpha_u-dev", "%3", :blocked, "needs input")

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

      enriched = AgentState.enrich_topology(topology, "devide_alpha_u-dev")

      agent_pane = Enum.find(enriched.panes, &(&1.id == "%3"))
      other_pane = Enum.find(enriched.panes, &(&1.id == "%4"))

      assert agent_pane.agent_state == :blocked
      assert agent_pane.agent_state_message == "needs input"
      refute Map.has_key?(other_pane, :agent_state)

      assert hd(enriched.windows).agent_state == :blocked
    end
  end
end
