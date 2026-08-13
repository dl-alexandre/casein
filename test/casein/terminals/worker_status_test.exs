defmodule Casein.Terminals.WorkerStatusTest do
  use ExUnit.Case, async: true

  alias Casein.Terminals.WorkerStatus

  @now ~U[2026-08-11 06:00:00Z]

  defp topology(panes, windows \\ nil) do
    windows =
      windows ||
        panes
        |> Enum.map(fn p ->
          %{
            id: Map.get(p, :window_id) || "w1",
            name: Map.get(p, :window_name) || "worker-demo",
            active: false
          }
        end)
        |> Enum.uniq_by(& &1.id)

    %{windows: windows, panes: panes}
  end

  defp pane(id, overrides \\ []) do
    Map.merge(
      %{
        id: id,
        window_id: "w1",
        window_name: "worker-demo",
        role: "agent",
        agent_state: :working,
        quiet?: false
      },
      Map.new(overrides)
    )
  end

  describe "project/2" do
    test "shapes a blocked worker with report blocked_on and issue binding" do
      topo =
        topology([
          pane("%3",
            agent_state: :blocked,
            agent_state_message: "need unlock",
            issue: 384,
            issue_title: "orch control plane",
            fleet_role: :worker,
            worktree_path: "/tmp/wt-worker",
            label: "worker: #384"
          )
        ])

      payload =
        WorkerStatus.project(topo,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%3",
          now: @now
        )

      assert payload.found? == true
      assert payload.workspace_id == "ws-1"
      assert payload.session == "casein_ws-1_main"
      assert payload.pane_id == "%3"
      assert payload.window_id == "w1"
      assert payload.window_name == "worker-demo"
      assert payload.agent_state == "blocked"
      assert payload.agent_state_message == "need unlock"
      assert payload.issue == 384
      assert payload.issue_title == "orch control plane"
      assert payload.fleet_role == "worker"
      assert payload.worktree_path == "/tmp/wt-worker"
      assert payload.label == "worker: #384"
      assert payload.blocked_on.kind == "report"
      assert payload.blocked_on.reason == "blocked"
      assert payload.blocked_on.detail == "need unlock"
      assert payload.needs_you? == true
      assert payload.note =~ "M2"
      refute payload.note =~ "worker_launch shipped"
    end

    test "stalled is derived blocked_on, not report" do
      topo =
        topology([
          pane("%5",
            agent_state: :stalled,
            agent_state_message: nil,
            liveness: %{state: :quiet, quiet_for_seconds: 900}
          )
        ])

      payload =
        WorkerStatus.project(topo,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%5",
          now: @now
        )

      assert payload.agent_state == "stalled"
      assert payload.blocked_on.kind == "derived"
      assert payload.blocked_on.reason == "stalled"
      assert payload.liveness.state == "quiet"
      assert payload.liveness.quiet_for_seconds == 900
    end

    test "liveness unknown never becomes quiet; missing liveness omitted" do
      unknown =
        topology([
          pane("%7",
            agent_state: :working,
            liveness: %{state: :unknown, reason: :unscanned}
          )
        ])
        |> WorkerStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%7",
          now: @now
        )

      assert unknown.liveness.state == "unknown"
      assert unknown.liveness.reason == "unscanned"
      refute unknown.liveness.state == "quiet"
      refute Map.get(unknown.liveness, :quiet_for_seconds)

      missing =
        topology([pane("%8", agent_state: :working)])
        |> WorkerStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%8",
          now: @now
        )

      refute Map.has_key?(missing, :liveness)
    end

    test "ready_no_task surfaces readiness clock" do
      topo =
        topology([
          pane("%9",
            agent_state: :idle,
            fleet_role: :worker,
            fleet_readiness: :ready_no_task,
            ready_no_task_for_seconds: 240
          )
        ])

      payload =
        WorkerStatus.project(topo,
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%9",
          now: @now
        )

      assert payload.fleet_readiness == "ready_no_task"
      assert payload.ready_no_task_for_seconds == 240
      # Capacity, not attention — the readiness clock still reports.
      assert payload.needs_you? == false
      assert payload.blocked_on.reason == "ready_no_task"
    end

    test "missing pane returns found? false without inventing idle" do
      payload =
        topology([pane("%1")])
        |> WorkerStatus.project(
          workspace_id: "ws-1",
          session: "casein_ws-1_main",
          pane: "%missing",
          now: @now
        )

      assert payload.found? == false
      assert payload.pane_id == "%missing"
      refute Map.get(payload, :agent_state) == "idle"
      refute Map.get(payload, :liveness)
    end

    test "optional window_id filters the match" do
      topo =
        topology(
          [
            pane("%3", window_id: "@1", window_name: "a"),
            pane("%3-dup", id: "%3", window_id: "@2", window_name: "b", agent_state: :blocked)
          ],
          [
            %{id: "@1", name: "a", active: false},
            %{id: "@2", name: "b", active: false}
          ]
        )

      # Without window_id, first match wins
      first =
        WorkerStatus.project(topo,
          workspace_id: "ws-1",
          session: "s",
          pane: "%3",
          now: @now
        )

      assert first.window_id == "@1"

      second =
        WorkerStatus.project(topo,
          workspace_id: "ws-1",
          session: "s",
          pane: "%3",
          window_id: "@2",
          now: @now
        )

      assert second.found? == true
      assert second.window_id == "@2"
      assert second.agent_state == "blocked"
    end
  end
end
