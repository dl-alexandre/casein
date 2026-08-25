defmodule CaseinWeb.WorkspaceHeaderHostHealthTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Casein.Terminals.HostHealth
  alias CaseinWeb.WorkspaceLive.Show.WorkspaceHeader

  test "overflow menu shows the same state and timestamp as the MCP snapshot" do
    snapshot =
      HostHealth.snapshot(
        status: %{
          "timestamp" => "2026-08-23T21:59:50Z",
          "load1" => 3.88,
          "runnable" => 7,
          "cpu_idle_pct" => 87,
          "mem_available_kb" => 65_464_848,
          "swap_used_kb" => 0,
          "d_state_processes" => 0,
          "d_state_streak" => 0,
          "opencode_processes" => 45,
          "beam_processes" => 1,
          "warning" => 0,
          "alert" => "none"
        },
        alerts: [],
        now: ~U[2026-08-23 22:00:00Z],
        host: "milc-devbox"
      )

    html =
      render_component(&WorkspaceHeader.header_overflow_menu/1,
        workspace: %{id: "ws-host-health", status: :running, branch: nil},
        workspace_start_error: nil,
        tab: "files",
        host_loc: {:error, :unavailable},
        tmux_mutations_enabled?: false,
        tmux_window_tabs: [],
        terminal_mode: :raw,
        tmux_session: "casein_test",
        terminal_sid: "sid",
        active_window_pane_count: 1,
        host_health: snapshot
      )

    assert html =~ ~s(id="host-health-ws-host-health")
    assert html =~ ~s(data-host-health-state="healthy")
    assert html =~ ~s(data-host-health-sampled-at="2026-08-23T21:59:50Z")
    assert html =~ "Host health"
    assert html =~ "Healthy"
    assert html =~ "milc-devbox"
    assert html =~ "load 3.88"
    assert html =~ "idle 87%"
    assert snapshot.state == "healthy"
    assert snapshot.sampled_at == "2026-08-23T21:59:50Z"
  end

  test "pressure and stuck rows stay visually distinct and show the latest alert time" do
    pressure =
      HostHealth.snapshot(
        status: %{
          "timestamp" => "2026-08-23T21:59:50Z",
          "load1" => 40.0,
          "runnable" => 40,
          "cpu_idle_pct" => 10,
          "mem_available_kb" => 1_000,
          "swap_used_kb" => 0,
          "d_state_processes" => 0,
          "d_state_streak" => 0,
          "opencode_processes" => 80,
          "beam_processes" => 1,
          "warning" => 1,
          "alert" => "pressure"
        },
        now: ~U[2026-08-23 22:00:00Z],
        host: "milc-devbox"
      )

    stuck =
      HostHealth.snapshot(
        status: %{
          "timestamp" => "2026-08-23T21:59:50Z",
          "load1" => 4.0,
          "runnable" => 4,
          "cpu_idle_pct" => 80,
          "mem_available_kb" => 10_000_000,
          "swap_used_kb" => 0,
          "d_state_processes" => 1,
          "d_state_streak" => 3,
          "opencode_processes" => 10,
          "beam_processes" => 1,
          "warning" => 0,
          "alert" => "d_state"
        },
        now: ~U[2026-08-23 22:00:00Z],
        host: "milc-devbox"
      )

    pressure_html = render_row(pressure)
    stuck_html = render_row(stuck)

    assert pressure.state == "pressure"
    assert stuck.state == "stuck"
    assert pressure_html =~ ~s(data-host-health-state="pressure")
    assert stuck_html =~ ~s(data-host-health-state="stuck")
    assert pressure_html =~ "Pressure"
    assert stuck_html =~ "Stuck"
    assert pressure_html =~ "2026-08-23T21:59:50Z"
    assert stuck_html =~ "2026-08-23T21:59:50Z"
    refute pressure_html =~ "Stuck"
    refute stuck_html =~ "Pressure"
  end

  test "unknown snapshots stay visibly unknown with a reason" do
    snapshot =
      HostHealth.snapshot(
        status_path: "/tmp/casein-missing-host-health.json",
        now: ~U[2026-08-23 22:00:00Z],
        host: "milc-devbox"
      )

    html = render_row(snapshot)

    assert snapshot.state == "unknown"
    assert html =~ ~s(data-host-health-state="unknown")
    assert html =~ "Unknown"
    assert html =~ "status snapshot is unavailable"
  end

  defp render_row(snapshot) do
    render_component(&WorkspaceHeader.header_overflow_menu/1,
      workspace: %{id: "ws-host-health", status: :running, branch: nil},
      workspace_start_error: nil,
      tab: "files",
      host_loc: {:error, :unavailable},
      tmux_mutations_enabled?: false,
      tmux_window_tabs: [],
      terminal_mode: :raw,
      tmux_session: "casein_test",
      terminal_sid: "sid",
      active_window_pane_count: 1,
      host_health: snapshot
    )
  end
end
