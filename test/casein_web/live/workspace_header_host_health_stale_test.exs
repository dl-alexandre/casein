defmodule CaseinWeb.WorkspaceHeaderHostHealthStaleTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Casein.Terminals.HostHealth
  alias CaseinWeb.WorkspaceLive.Show.WorkspaceHeader

  # OneBackend-v3#20165: the row served 3-day-old crash numbers as if current.
  test "a stale snapshot shows how long the watchdog has been silent, not frozen numbers" do
    snapshot =
      HostHealth.snapshot(
        status: %{
          "timestamp" => "2026-08-27T21:10:23Z",
          "load1" => 781.49,
          "runnable" => 4,
          "cpu_idle_pct" => 0,
          "mem_available_kb" => 15_095_408,
          "swap_used_kb" => 0,
          "d_state_processes" => 224,
          "d_state_streak" => 10,
          "opencode_processes" => 66,
          "beam_processes" => 9,
          "warning" => 1,
          "alert" => "pressure_and_d_state"
        },
        alerts_raw: nil,
        now: ~U[2026-08-30 16:03:36Z],
        host: "milc-devbox"
      )

    html = render_menu(snapshot)

    assert html =~ ~s(data-host-health-state="stale")
    assert html =~ "Stale"
    assert html =~ "silent for 66h"
    assert html =~ "2026-08-27T21:10:23Z"
    assert html =~ "last recorded: stuck"
    refute html =~ "load 781.49"
    assert html =~ "alert log unavailable"
    refute snapshot.alerts_available?
    assert snapshot.alerts_unavailable_reason =~ "malformed"
  end

  test "a fresh snapshot still shows the live numbers and no silence banner" do
    snapshot =
      HostHealth.snapshot(
        status: %{
          "timestamp" => "2026-08-30T16:03:26Z",
          "load1" => 11.36,
          "runnable" => 7,
          "cpu_idle_pct" => 80,
          "mem_available_kb" => 80_344_404,
          "swap_used_kb" => 0,
          "d_state_processes" => 0,
          "d_state_streak" => 0,
          "opencode_processes" => 1,
          "beam_processes" => 4,
          "warning" => 0,
          "alert" => "none"
        },
        alerts: [],
        now: ~U[2026-08-30 16:03:36Z],
        host: "milc-devbox"
      )

    html = render_menu(snapshot)

    assert html =~ "load 11.36"
    refute html =~ "silent for"
    refute html =~ "alert log unavailable"
  end

  defp render_menu(snapshot) do
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
