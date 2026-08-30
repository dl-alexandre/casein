defmodule Casein.Terminals.AgentStateProvenanceTest do
  @moduledoc """
  OneBackend-v3#20022: an expired report must not look like a pane that never
  reported, and the last report must survive expiry (and a restart).
  """
  use Casein.TestCase, async: false

  alias Casein.Agents.AgentEvents
  alias Casein.Terminals.AgentState

  @session "casein_ws-1_provenance"

  setup do
    AgentState.clear()
    AgentEvents.clear()

    on_exit(fn ->
      AgentState.clear()
      AgentEvents.clear()
    end)

    :ok
  end

  describe "resolution_for/2" do
    test "names the four conditions" do
      entry = %{state: :blocked, reported_at: DateTime.utc_now()}

      assert AgentState.resolution_for(entry, {:blocked, nil}) == :report
      assert AgentState.resolution_for(entry, {:unknown, nil}) == :expired_report
      assert AgentState.resolution_for(nil, {:unknown, nil}) == :unreported
      assert AgentState.resolution_for(nil, {:stalled, nil}) == :derived
      assert AgentState.resolution_for(entry, {:awaiting_input, nil}) == :derived
    end
  end

  describe "enrich_topology/2 provenance" do
    test "a live report is asserted with :report provenance and its freshness" do
      AgentState.report("ws-1", @session, "%1", :blocked, "need you")

      [pane] = enrich([pane("%1", :ready)])

      assert pane.agent_state == :blocked
      assert pane.agent_state_resolution == :report
      assert pane.agent_state_last_reported == :blocked
      assert pane.agent_state_report_source == :mcp
      assert is_binary(pane.agent_state_reported_at)
      assert pane.agent_state_age_s in 0..5
    end

    test "an expired report is not asserted but is still on the record" do
      AgentState.report("ws-1", @session, "%1", :blocked, "need you")
      age_report("%1", 6 * 3600)

      [pane] = enrich([pane("%1", :ready)])

      refute Map.has_key?(pane, :agent_state)
      assert pane.agent_state_resolution == :expired_report
      assert pane.agent_state_last_reported == :blocked
      assert pane.agent_state_age_s >= 6 * 3600
      assert {:ok, at, _} = DateTime.from_iso8601(pane.agent_state_reported_at)
      assert DateTime.diff(DateTime.utc_now(), at, :second) >= 6 * 3600
    end

    test "a blocked report aged past the assert window is an expired report, not silence" do
      AgentState.report("ws-1", @session, "%1", :blocked, "need you")
      age_report("%1", AgentState.stale_assert_seconds() + 30)

      [pane] = enrich([pane("%1", :ready)])

      refute Map.has_key?(pane, :agent_state)
      assert pane.agent_state_resolution == :expired_report
      assert pane.agent_state_last_reported == :blocked
    end

    test "a pane that never reported says so, with no last-report fields" do
      [pane] = enrich([pane("%9", :ready)])

      refute Map.has_key?(pane, :agent_state)
      assert pane.agent_state_resolution == :unreported
      refute Map.has_key?(pane, :agent_state_last_reported)
      refute Map.has_key?(pane, :agent_state_reported_at)
    end

    test "a derived verdict is tagged :derived even with no report" do
      [pane] =
        enrich([
          pane("%1", :working)
          |> Map.put(:liveness, %{quiet_for_seconds: AgentState.stall_seconds() + 60})
        ])

      assert pane.agent_state == :stalled
      assert pane.agent_state_resolution == :derived
    end
  end

  describe "rehydration from the durable timeline" do
    test "the newest durable transition per pane seeds the store after a restart" do
      transition("%1", "working", nil)
      transition("%1", "done", "working")
      transition("%2", "blocked", "working")

      AgentState.clear()
      assert AgentState.get(@session, "%1") == nil

      assert {:ok, 2} = AgentState.Server.rehydrate()

      assert %{state: :done, source: :durable, message: nil, workspace_id: "ws-1"} =
               AgentState.get(@session, "%1")

      assert %{state: :blocked, source: :durable} = AgentState.get(@session, "%2")
    end

    test "a live entry is never overwritten by the durable record" do
      transition("%1", "done", "working")
      AgentState.clear()
      AgentState.report("ws-1", @session, "%1", :working)

      assert {:ok, 0} = AgentState.Server.rehydrate()
      assert %{state: :working, source: :mcp} = AgentState.get(@session, "%1")
    end

    test "a rehydrated entry projects as an expired report with its last word" do
      transition("%1", "blocked", "working")
      AgentState.clear()
      {:ok, _} = AgentState.Server.rehydrate()
      age_report("%1", 3 * 3600)

      [pane] = enrich([pane("%1", :ready)])

      refute Map.has_key?(pane, :agent_state)
      assert pane.agent_state_resolution == :expired_report
      assert pane.agent_state_last_reported == :blocked
      assert pane.agent_state_report_source == :durable
    end
  end

  defp transition(pane, state, prior) do
    {:ok, _event, :inserted} =
      AgentEvents.append_state_transition(%{
        workspace_id: "ws-1",
        tmux_session_id: @session,
        pane_id: pane,
        state: state,
        prior_state: prior,
        source: "hook"
      })
  end

  defp pane(id, heuristic), do: %{id: id, pane_state: heuristic}

  defp enrich(panes) do
    %{panes: panes, windows: []}
    |> AgentState.enrich_topology(@session)
    |> Map.fetch!(:panes)
  end

  # Reports are stamped with wall-clock time on arrival; backdate one in place.
  defp age_report(pane, seconds) do
    key = {@session, pane}
    at = DateTime.add(DateTime.utc_now(), -seconds, :second)

    :sys.replace_state(Casein.Terminals.AgentState, fn state ->
      update_in(state, [:entries, key], &%{&1 | reported_at: at})
    end)
  end
end
