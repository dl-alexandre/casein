defmodule Casein.Terminals.FleetSummaryTest do
  # Shares Application env for the process-liveness ETS table with other
  # PaneProcessLiveness tests — must not run async against those.
  use ExUnit.Case, async: false

  alias Casein.Terminals.FleetSummary
  alias Casein.Terminals.PaneProcessLiveness

  defmodule FakeTmux do
    def session_topology(_session) do
      windows = [
        %{
          id: "@1",
          index: 0,
          name: "worker-demo",
          manual_name: true,
          active: true,
          panes: 1,
          activity: 100,
          current_command: "opencode"
        }
      ]

      panes = [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 80,
          height: 24,
          current_command: "opencode",
          current_path: System.tmp_dir!(),
          pane_title: "opencode",
          role: "agent",
          paired: true,
          paired_reason: "role",
          activity: 100,
          activity_flag: false,
          bell: false,
          unseen_changes: false,
          zoomed?: false
        }
      ]

      {windows, panes}
    end

    def list_session_windows(session) do
      {windows, _} = session_topology(session)
      windows
    end

    def list_session_panes(session) do
      {_, panes} = session_topology(session)
      panes
    end
  end

  setup do
    table = :"fleet_sum_#{System.unique_integer([:positive])}"
    previous = Application.get_env(:casein, :pane_process_liveness_cache_table)
    Application.put_env(:casein, :pane_process_liveness_cache_table, table)
    on_exit(fn -> Application.put_env(:casein, :pane_process_liveness_cache_table, previous) end)
    PaneProcessLiveness.ensure_cache_table()
    :ok
  end

  test "resource descriptor advertises casein://fleet/summary" do
    desc = FleetSummary.resource_descriptor()
    assert desc.uri == "casein://fleet/summary"
    assert desc.mimeType == "application/json"
    assert desc.description =~ "process/CPU"
    assert desc.description =~ "running_but_not_progressing"
  end

  test "build projects sessions/panes with process_cpu liveness source" do
    seeds = %{"%1" => %{pid: 4242, current_command: "opencode"}}

    # Warm the process sample so a second build can show active.
    _ =
      PaneProcessLiveness.observe_session(
        "casein_ws-1_main",
        now_ms: 1_000,
        pid_reader: fn _ -> seeds end,
        stat_reader: fn 4242 -> {:ok, 10} end,
        children_reader: fn _ -> [] end
      )

    payload =
      FleetSummary.build(
        workspace_id: "ws-1",
        sessions: [%{session: "casein_ws-1_main", attached: true, activity: 100}],
        now: ~U[2026-08-11 12:00:00Z],
        tmux: FakeTmux,
        git: false,
        process_liveness_opts: [
          now_ms: 2_000,
          pid_reader: fn _ -> seeds end,
          stat_reader: fn 4242 -> {:ok, 80} end,
          children_reader: fn _ -> [] end
        ],
        progress_opts: [
          now_ms: 2_000,
          screen_reader: fn _, _ ->
            {:ok, "Permission required\n❯ Allow once\n  Reject"}
          end,
          git_reader: fn _ -> %{available?: false} end
        ]
      )

    assert payload.uri == "casein://fleet/summary"
    assert payload.workspace_id == "ws-1"
    assert payload.incomplete == false
    assert is_nil(payload.incomplete_reason)
    assert payload.session_count == 1
    assert payload.pane_count == 1
    assert payload.note =~ "process/CPU"
    assert payload.note =~ "running_but_not_progressing"

    [session] = payload.sessions
    assert session.session == "casein_ws-1_main"
    [pane] = session.panes
    assert pane.pane_id == "%1"
    assert pane.runtime == "opencode"
    assert pane.agent_state == "blocked"
    assert pane.agent_state_provenance == "screen"
    assert pane.liveness.source == "process_cpu"
    assert pane.liveness.state == "active"
    assert pane.liveness.cpu_jiffies_delta == 70
    assert is_map(pane.progress)
    assert pane.progress.state in ~w(unknown progressing quiet running_but_not_progressing)
    # Fake cwd is not a git checkout; worktree_path is omitted (reject_nil).
    # Production panes under a worktree get branch/ahead via Git.Inspector.
    refute Map.has_key?(pane, :worktree_path)
  end

  test "to_json is valid JSON with string keys" do
    payload =
      FleetSummary.build(
        workspace_id: "ws-1",
        sessions: [%{session: "casein_ws-1_main"}],
        tmux: FakeTmux,
        git: false,
        process_liveness_opts: [
          now_ms: 1,
          pid_reader: fn _ -> %{"%1" => %{pid: 1, current_command: "bash"}} end,
          stat_reader: fn 1 -> {:ok, 1} end,
          children_reader: fn _ -> [] end
        ]
      )

    json = FleetSummary.to_json(payload)
    decoded = Jason.decode!(json)
    assert decoded["uri"] == "casein://fleet/summary"
    assert is_list(decoded["sessions"])
  end

  test "empty sessions list yields empty fleet without crashing" do
    payload = FleetSummary.build(workspace_id: "ws-1", sessions: [])
    assert payload.session_count == 0
    assert payload.pane_count == 0
    assert payload.sessions == []
    assert payload.incomplete == false
  end

  test "budget expiry returns incomplete rather than hanging" do
    payload =
      FleetSummary.build(
        workspace_id: "ws-1",
        sessions: [%{session: "casein_ws-1_a"}, %{session: "casein_ws-1_b"}],
        tmux: FakeTmux,
        git: false,
        budget_ms: 0
      )

    assert payload.incomplete == true
    assert payload.incomplete_reason == "refresh_budget_exceeded"
    assert payload.sessions == []
  end
end
