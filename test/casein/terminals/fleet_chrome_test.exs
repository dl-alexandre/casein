defmodule Casein.Terminals.FleetChromeTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.FleetChrome

  describe "role_from_text/1" do
    test "parses manager and worker labels" do
      assert FleetChrome.role_from_text("manager") == :manager
      assert FleetChrome.role_from_text("manager: fleet host") == :manager
      assert FleetChrome.role_from_text("Manager - solo") == :manager
      assert FleetChrome.role_from_text("worker") == :worker
      assert FleetChrome.role_from_text("worker: #744 item 4") == :worker
      assert FleetChrome.role_from_text("worker-oc-744-fleet") == :worker
    end

    test "rejects near-miss tokens" do
      assert FleetChrome.role_from_text("managerial") == nil
      assert FleetChrome.role_from_text("workers") == nil
      assert FleetChrome.role_from_text("implementer") == nil
      assert FleetChrome.role_from_text("") == nil
    end
  end

  describe "enrich_pane/2" do
    test "attaches fleet_role from label" do
      pane = agent(%{label: "manager: window-0", pane_state: :ready})

      assert %{fleet_role: :manager} = FleetChrome.enrich_pane(pane, 60)
    end

    test "attaches fleet_role from spawn window name" do
      pane = agent(%{window_name: "worker-oc-744-fleet", pane_state: :ready})

      assert %{fleet_role: :worker} = FleetChrome.enrich_pane(pane, 60)
    end

    test "ready_no_task when idle agent has no issue, no task, and is quiet long enough" do
      pane =
        agent(%{
          pane_state: :ready,
          agent_state: :idle,
          liveness: %{quiet_for_seconds: 300}
        })

      assert %{
               fleet_readiness: :ready_no_task,
               ready_no_task_for_seconds: 300
             } = FleetChrome.enrich_pane(pane, 120)
    end

    test "uses agent_state_age_s when liveness is absent" do
      pane =
        agent(%{
          pane_state: :ready,
          agent_state: :idle,
          agent_state_age_s: 180
        })

      assert %{fleet_readiness: :ready_no_task, ready_no_task_for_seconds: 180} =
               FleetChrome.enrich_pane(pane, 120)
    end

    test "does not mark ready_no_task below the quiet threshold" do
      pane =
        agent(%{
          pane_state: :ready,
          agent_state: :idle,
          liveness: %{quiet_for_seconds: 30}
        })

      enriched = FleetChrome.enrich_pane(pane, 120)
      refute Map.has_key?(enriched, :fleet_readiness)
    end

    test "issue binding means the pane has a task" do
      pane =
        agent(%{
          pane_state: :ready,
          agent_state: :idle,
          issue: 744,
          liveness: %{quiet_for_seconds: 600}
        })

      enriched = FleetChrome.enrich_pane(pane, 120)
      refute Map.has_key?(enriched, :fleet_readiness)
    end

    test "real task_summary means the pane has a task" do
      pane =
        agent(%{
          pane_state: :ready,
          task_summary: "Ship fleet chrome",
          liveness: %{quiet_for_seconds: 600}
        })

      enriched = FleetChrome.enrich_pane(pane, 120)
      refute Map.has_key?(enriched, :fleet_readiness)
    end

    test "working panes are never ready_no_task" do
      pane =
        agent(%{
          pane_state: :working,
          agent_state: :working,
          liveness: %{quiet_for_seconds: 600}
        })

      enriched = FleetChrome.enrich_pane(pane, 120)
      refute Map.has_key?(enriched, :fleet_readiness)
    end

    test "non-agent panes are ignored" do
      pane = %{
        id: "%9",
        role: "operator",
        pane_state: :ready,
        liveness: %{quiet_for_seconds: 600}
      }

      enriched = FleetChrome.enrich_pane(pane, 120)
      refute Map.has_key?(enriched, :fleet_readiness)
      refute Map.has_key?(enriched, :fleet_role)
    end
  end

  describe "enrich_topology/2" do
    test "projects role and readiness onto panes and agent windows" do
      topology = %{
        panes: [
          agent(%{
            id: "%1",
            window_id: "@1",
            label: "worker: item 4",
            pane_state: :ready,
            agent_state: :idle,
            liveness: %{quiet_for_seconds: 400}
          }),
          %{id: "%2", window_id: "@1", role: "operator", pane_state: :unknown}
        ],
        windows: [
          %{
            id: "@1",
            name: "worker-oc-744",
            pane_list: [
              %{id: "%1", role: "agent"},
              %{id: "%2", role: "operator"}
            ]
          }
        ]
      }

      assert %{
               panes: [worker, operator],
               windows: [window]
             } = FleetChrome.enrich_topology(topology, ready_seconds: 120)

      assert worker.fleet_role == :worker
      assert worker.fleet_readiness == :ready_no_task
      assert worker.ready_no_task_for_seconds == 400
      refute Map.has_key?(operator, :fleet_role)
      assert window.fleet_role == :worker
      assert window.fleet_readiness == :ready_no_task
    end
  end

  defp agent(attrs) do
    Map.merge(
      %{
        id: "%1",
        window_id: "@1",
        role: "agent",
        pane_state: :unknown
      },
      attrs
    )
  end
end
