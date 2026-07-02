defmodule DevIdeWeb.WorkspaceLive.Show.WindowTerminalModeTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode

  test "active_window_name/1 returns the name of the active tmux window" do
    socket = %{
      assigns: %{
        tmux_active_window_id: "@1",
        tmux_windows: [%{id: "@0", name: "shell"}, %{id: "@1", name: "agents"}]
      }
    }

    assert "agents" = WindowTerminalMode.active_window_name(socket)
  end

  test "active_window_metadata/1 includes id and name when present" do
    socket = %{
      assigns: %{
        tmux_active_window_id: "@1",
        tmux_windows: [%{id: "@1", name: "agents"}]
      }
    }

    assert %{
             "tmux_window_id" => "@1",
             "tmux_window_name" => "agents"
           } = WindowTerminalMode.active_window_metadata(socket)
  end

  test "set_mode/2 (re)starts the raw Ghostty pane for the active window" do
    socket = window_mode_socket(%{terminal_mode: :raw})

    socket = WindowTerminalMode.set_mode(socket, :raw)

    assert socket.assigns.pane_data["pane-1"].error == :workspace_not_running
  end

  test "apply_for_active_window/1 is a no-op when there is no active window" do
    socket = window_mode_socket(%{tmux_active_window_id: nil})

    assert WindowTerminalMode.apply_for_active_window(socket) == socket
  end

  defp window_mode_socket(extra_assigns) do
    base = %{
      host_id: "local",
      tmux_windows: [%{id: "@0", name: "shell"}],
      tmux_active_window_id: "@0",
      terminal_sid: "u-dev",
      terminal_mode: :raw,
      workspace: %{id: "ws-1", name: "alpha", status: :error},
      focused_pane_id: "pane-1",
      pane_data: %{
        "pane-1" => %{
          ghostty_term: nil,
          ghostty_pty: nil,
          worker: nil,
          backend: nil,
          session_sid: "u-dev",
          tmux_session: "devide_alpha_u-dev",
          cols: 120,
          rows: 40,
          error: nil,
          auto_retry_count: 0
        }
      }
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, Map.merge(base, extra_assigns))
    }
  end
end
