defmodule CaseinWeb.HostHealthMenuTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.WorkspaceHeader

  test "overflow menu embeds host health without a separate dashboard" do
    html =
      render_component(&WorkspaceHeader.header_overflow_menu/1,
        desktop_terminal?: true,
        workspace: %{id: "ws-health", status: :running, branch: nil},
        workspace_start_error: nil,
        tab: "terminal",
        host_loc: {:ok, {:local, System.user_home!()}},
        tmux_mutations_enabled?: false,
        tmux_window_tabs: [],
        terminal_mode: :raw_ghostty,
        tmux_session: "desktop",
        terminal_sid: "ws-health",
        active_window_pane_count: 1,
        host_health: %{
          uri: "casein://host/health",
          host: "test-host",
          state: "unknown",
          reason: "unavailable",
          sampled_at: nil,
          sample_age_seconds: nil,
          fresh?: false,
          stale_after_seconds: 900,
          metrics: nil,
          alert: %{signal: "none", warning?: false, at: nil},
          alerts: [],
          generated_at: "2026-08-22T22:00:00Z"
        }
      )

    assert html =~ ~s(id="host-health-ws-health")
    assert html =~ "Host health"
    assert html =~ "Unknown"
    assert html =~ "unavailable"
    assert html =~ ~s(phx-click="host_health:refresh")
  end

  test "pressure and stuck are visually distinct" do
    pressure =
      render_component(&WorkspaceHeader.header_overflow_menu/1, menu_assigns(state: "pressure"))

    stuck =
      render_component(&WorkspaceHeader.header_overflow_menu/1, menu_assigns(state: "stuck"))

    assert pressure =~ "Pressure"
    assert stuck =~ "Stuck"
    assert pressure =~ "bg-status-warning"
    assert stuck =~ "bg-status-danger"
    refute pressure =~ "bg-status-danger/15"
    refute stuck =~ "bg-status-warning/15"
  end

  defp menu_assigns(opts) do
    state = Keyword.fetch!(opts, :state)

    health = %{
      uri: "casein://host/health",
      host: "test-host",
      state: state,
      reason: nil,
      sampled_at: "2026-08-22T21:59:30Z",
      sample_age_seconds: 30,
      fresh?: true,
      stale_after_seconds: 900,
      metrics: %{
        load1: 33.0,
        runnable: 40,
        cpu_idle_pct: 15,
        mem_available_kb: 1_000_000,
        swap_used_kb: 0,
        opencode_processes: 4,
        beam_processes: 1,
        d_state_processes: 0,
        d_state_streak: 0
      },
      alert: %{
        signal: if(state == "stuck", do: "d_state", else: "pressure"),
        warning?: true,
        at: "2026-08-22T21:59:30Z"
      },
      alerts: [],
      generated_at: "2026-08-22T22:00:00Z"
    }

    [
      desktop_terminal?: true,
      workspace: %{id: "ws-health", status: :running, branch: nil},
      workspace_start_error: nil,
      tab: "terminal",
      host_loc: {:ok, {:local, System.user_home!()}},
      tmux_mutations_enabled?: false,
      tmux_window_tabs: [],
      terminal_mode: :raw_ghostty,
      tmux_session: "desktop",
      terminal_sid: "ws-health",
      active_window_pane_count: 1,
      host_health: health
    ]
  end
end
