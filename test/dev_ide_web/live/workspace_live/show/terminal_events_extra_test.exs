defmodule DevIdeWeb.WorkspaceLive.Show.TerminalEventsExtraTest do
  use DevIDE.TestCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TerminalEvents

  # Covers the pure handle_event clauses of TerminalEvents — ones that only
  # update socket assigns / put_flash / push_event, plus the deterministic
  # mutation-denied branches and the no-match guard clauses.
  #
  # SKIPPED (exercised through the full LiveView elsewhere): every clause that
  # calls TerminalState.* / Show.* / Tmux adapter IO on a non-no-op path —
  # tmux:refresh_windows, tmux:refresh_topology, tmux:resize_pane_finish,
  # tmux:new_window(_tab), tmux:select_window, tmux:select_pane, tmux:kill_pane,
  # tmux:split_pane, tmux:resize_pane(_step ok path), tmux:rename_window,
  # terminal:rename_session, tmux:last_window, tmux:cycle_window, pane:navigate (ok path),
  # tmux:kill_window, terminal:set_mode (Ghostty restart), attach_terminal_session,
  # terminal:switch_to_shell, terminal:refresh_sessions, terminal:kill_session,
  # terminal:picker_preview (capture_scrollback). These need a tmux adapter +
  # topology fakes, not a bare socket.

  defp socket(assigns) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)
    }
  end

  test "terminal:user_interaction stamps the last-interaction clock" do
    s = socket(%{terminal_last_interaction_ms: nil})

    assert {:noreply, s2} =
             TerminalEvents.handle_event("terminal:user_interaction", %{}, s)

    assert is_integer(s2.assigns.terminal_last_interaction_ms)
  end

  test "terminal:scheme assigns :light for light and :dark otherwise (no workers)" do
    s = socket(%{pane_data: %{}, terminal_color_scheme: nil})

    assert {:noreply, light} =
             TerminalEvents.handle_event("terminal:scheme", %{"scheme" => "light"}, s)

    assert light.assigns.terminal_color_scheme == :light

    assert {:noreply, dark} =
             TerminalEvents.handle_event("terminal:scheme", %{"scheme" => "dark"}, s)

    assert dark.assigns.terminal_color_scheme == :dark

    # any non-"light" value falls through to :dark
    assert {:noreply, other} =
             TerminalEvents.handle_event("terminal:scheme", %{"scheme" => "sepia"}, s)

    assert other.assigns.terminal_color_scheme == :dark
  end

  test "terminal:scheme tolerates a nil pane_data assign" do
    s = socket(%{pane_data: nil, terminal_color_scheme: nil})

    assert {:noreply, s2} =
             TerminalEvents.handle_event("terminal:scheme", %{"scheme" => "light"}, s)

    assert s2.assigns.terminal_color_scheme == :light
  end

  test "terminal:set_preset ignores an invalid preset" do
    s = socket(%{pane_data: %{}, terminal_preset_id: "catppuccin"})

    assert {:noreply, s2} =
             TerminalEvents.handle_event(
               "terminal:set_preset",
               %{"preset" => "not-a-real-preset"},
               s
             )

    assert s2.assigns.terminal_preset_id == "catppuccin"
    refute Map.has_key?(s2.assigns, :terminal_themes)
  end

  test "terminal:set_preset assigns a valid built-in preset and its themes" do
    s = socket(%{pane_data: %{}, terminal_preset_id: nil})

    assert {:noreply, s2} =
             TerminalEvents.handle_event(
               "terminal:set_preset",
               %{"preset" => "catppuccin"},
               s
             )

    assert s2.assigns.terminal_preset_id == "catppuccin"
    assert is_map(s2.assigns.terminal_themes)
    assert s2.assigns.terminal_themes.preset == "catppuccin"
  end

  test "tmux:rename_start opens the window-rename input when mutations are allowed" do
    s =
      socket(%{
        tmux_mutations_enabled?: true,
        tmux_rename_window_id: nil,
        tmux_rename_session_id: "stale"
      })

    assert {:noreply, s2} =
             TerminalEvents.handle_event(
               "tmux:rename_start",
               %{"window-id" => "@7"},
               s
             )

    assert s2.assigns.tmux_rename_window_id == "@7"
    assert s2.assigns.tmux_rename_session_id == nil
  end

  test "tmux:rename_start is denied when mutations are disabled" do
    s = socket(%{tmux_mutations_enabled?: false})

    assert {:noreply, s2} =
             TerminalEvents.handle_event(
               "tmux:rename_start",
               %{"window-id" => "@7"},
               s
             )

    assert s2.assigns.flash["error"] =~ "not allowed"
    refute Map.has_key?(s2.assigns, :tmux_rename_window_id)
  end

  test "tmux:rename_cancel clears the window-rename input" do
    s = socket(%{tmux_rename_window_id: "@7"})

    assert {:noreply, s2} =
             TerminalEvents.handle_event("tmux:rename_cancel", %{}, s)

    assert s2.assigns.tmux_rename_window_id == nil
  end

  test "terminal:rename_session_start opens the session-rename input when allowed" do
    s =
      socket(%{
        tmux_mutations_enabled?: true,
        tmux_rename_session_id: nil,
        tmux_rename_window_id: "@stale"
      })

    assert {:noreply, s2} =
             TerminalEvents.handle_event(
               "terminal:rename_session_start",
               %{"session-id" => "sess-1"},
               s
             )

    assert s2.assigns.tmux_rename_session_id == "sess-1"
    assert s2.assigns.tmux_rename_window_id == nil
  end

  test "terminal:rename_session_start is denied when mutations are disabled" do
    s = socket(%{tmux_mutations_enabled?: false})

    assert {:noreply, s2} =
             TerminalEvents.handle_event(
               "terminal:rename_session_start",
               %{"session-id" => "sess-1"},
               s
             )

    assert s2.assigns.flash["error"] =~ "not allowed"
    refute Map.has_key?(s2.assigns, :tmux_rename_session_id)
  end

  test "terminal:rename_session_cancel clears the session-rename input" do
    s = socket(%{tmux_rename_session_id: "sess-1"})

    assert {:noreply, s2} =
             TerminalEvents.handle_event("terminal:rename_session_cancel", %{}, s)

    assert s2.assigns.tmux_rename_session_id == nil
  end

  test "tmux:resize_pane_step replies with a disabled error when mutations are off" do
    s = socket(%{tmux_mutations_enabled?: false})

    assert {:reply, %{ok: false, reason: "mutations_disabled"}, ^s} =
             TerminalEvents.handle_event(
               "tmux:resize_pane_step",
               %{"pane-id" => "%1", "direction" => "left"},
               s
             )
  end

  test "pane:navigate raises on an unsupported direction (no catch-all clause)" do
    s = socket(%{tmux_session: "ws"})

    assert_raise FunctionClauseError, fn ->
      TerminalEvents.handle_event("pane:navigate", %{"dir" => "diagonal"}, s)
    end
  end

  test "tmux:resize_pane raises on an unsupported direction (guarded clause)" do
    s = socket(%{tmux_mutations_enabled?: true, tmux_session: "ws"})

    assert_raise FunctionClauseError, fn ->
      TerminalEvents.handle_event(
        "tmux:resize_pane",
        %{"pane-id" => "%1", "direction" => "sideways"},
        s
      )
    end
  end

  test "tmux:cycle_window raises on an unsupported direction (guarded clause)" do
    s = socket(%{tmux_session: "ws"})

    assert_raise FunctionClauseError, fn ->
      TerminalEvents.handle_event("tmux:cycle_window", %{"dir" => "spin"}, s)
    end
  end
end
