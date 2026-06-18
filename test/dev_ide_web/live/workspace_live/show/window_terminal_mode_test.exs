defmodule DevIdeWeb.WorkspaceLive.Show.WindowTerminalModeTest do
  use ExUnit.Case, async: true

  alias DevIDE.Terminals.ModePolicy
  alias DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode

  test "decode_modes/1 accepts string modes from sessionStorage JSON" do
    assert %{"@0" => :raw, "@1" => :governed} =
             WindowTerminalMode.decode_modes(%{"@0" => "raw", "@1" => "governed"})
  end

  test "encode_modes/1 serializes for the browser hook" do
    assert %{"@0" => "raw"} = WindowTerminalMode.encode_modes(%{"@0" => :raw})
  end

  test "decode_storage_payload/1 reads full browser payload" do
    assert {%{"@0" => :raw}, %{"agents" => :governed}, true} =
             WindowTerminalMode.decode_storage_payload(%{
               "modes" => %{"@0" => "raw"},
               "names" => %{"agents" => "governed"},
               "new_windows_raw" => true
             })
  end

  test "decode_storage_payload/1 accepts legacy modes-only map" do
    assert {%{"@0" => :raw}, %{}, false} =
             WindowTerminalMode.decode_storage_payload(%{"@0" => "raw"})
  end

  test "restore_from_client starts raw pane even when terminal mode is already raw" do
    socket =
      window_mode_socket(%{
        terminal_mode: :raw,
        workspace_mode: :manual,
        workspace: %{id: "ws-1", name: "alpha", status: :error},
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
      })

    socket = WindowTerminalMode.restore_from_client(socket, %{"modes" => %{"@0" => "raw"}})

    assert socket.assigns.pane_data["pane-1"].error == :workspace_not_running
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

  test "window_mode_flags/2 marks governed override on manual workspaces" do
    socket = %{
      assigns: %{
        workspace_mode: :manual,
        host_id: "local",
        window_terminal_modes: %{},
        window_terminal_mode_names: %{"shell" => :governed}
      }
    }

    assert %{raw_remembered?: false, gov_remembered?: true} =
             WindowTerminalMode.window_mode_flags(socket, %{id: "@9", name: "shell"})
  end

  test "mode_for_window_id/1 falls back to window name when id changes" do
    socket = %{
      assigns: %{
        workspace_mode: :review,
        host_id: "local",
        new_windows_default_raw?: false,
        window_terminal_modes: %{},
        window_terminal_mode_names: %{"agents" => :raw},
        tmux_windows: [%{id: "@2", name: "agents"}]
      }
    }

    assert :raw = WindowTerminalMode.mode_for_window_id(socket, "@2")
  end

  test "query_mode_param/2 returns raw for remembered raw windows" do
    socket = %{
      assigns: %{
        workspace_mode: :review,
        host_id: "local",
        new_windows_default_raw?: false,
        window_terminal_modes: %{"@0" => :raw},
        window_terminal_mode_names: %{},
        tmux_windows: [%{id: "@0", name: "shell"}]
      }
    }

    assert "raw" = WindowTerminalMode.query_mode_param(socket, "@0")
    assert WindowTerminalMode.query_mode_param(socket, "@1") == nil
  end

  test "rename_window/3 migrates name-keyed preferences" do
    socket =
      window_mode_socket(%{
        window_terminal_modes: %{"@0" => :raw},
        window_terminal_mode_names: %{"shell" => :raw, "agents" => :governed},
        tmux_windows: [%{id: "@0", name: "shell"}]
      })

    socket = WindowTerminalMode.rename_window(socket, "@0", "main")

    assert socket.assigns.window_terminal_mode_names == %{
             "main" => :raw,
             "agents" => :governed
           }
  end

  test "stash_url_mode/2 records pending raw from query param" do
    socket = window_mode_socket(%{})
    socket = WindowTerminalMode.stash_url_mode(socket, "raw")
    assert socket.assigns.pending_url_terminal_mode == :raw

    socket = WindowTerminalMode.stash_url_mode(socket, "governed")
    assert socket.assigns.pending_url_terminal_mode == nil
  end

  test "default_mode uses new_windows_default_raw? when policy allows raw" do
    socket = %{
      assigns: %{
        workspace_mode: :review,
        host_id: "local",
        new_windows_default_raw?: true,
        window_terminal_modes: %{},
        window_terminal_mode_names: %{},
        tmux_windows: []
      }
    }

    assert :raw = WindowTerminalMode.mode_for_window_id(socket, "@9")
    assert ModePolicy.initial_mode(:review, "local") == :governed
  end

  defp window_mode_socket(extra_assigns) do
    base = %{
      workspace_mode: :review,
      host_id: "local",
      window_terminal_modes: %{},
      window_terminal_mode_names: %{},
      new_windows_default_raw?: false,
      tmux_windows: [],
      tmux_active_window_id: "@0",
      tmux_topology_version: 1,
      terminal_sid: "u-dev",
      terminal_mode: :governed,
      session_tabs: [],
      workspace: %{id: "ws-1"},
      focused_pane_id: "pane-1",
      pane_data: %{}
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}}, Map.merge(base, extra_assigns))
    }
  end
end
