defmodule DevIdeWeb.WorkspaceLive.TerminalSurfaceTest do
  use DevIdeWeb.ConnCase, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  describe "terminal_surface_pane_id/4" do
    test "keeps the sticky operator pane when a preview pane becomes tmux-active" do
      panes = [
        %{id: "%1", active: false},
        %{id: "%2", active: true}
      ]

      preview_panes = %{"%2" => %{pane_id: "%2"}}

      assert TerminalChrome.terminal_surface_pane_id(panes, preview_panes, "%2", "%1") == "%1"
    end

    test "follows tmux-active pane when another operator pane becomes active" do
      panes = [
        %{id: "%1", active: false},
        %{id: "%2", active: true}
      ]

      assert TerminalChrome.terminal_surface_pane_id(panes, %{}, "%2", "%1") == "%2"
    end

    test "adopts tmux-active pane on first mount when previous is missing" do
      panes = [
        %{id: "%1", active: false},
        %{id: "%2", active: true}
      ]

      assert TerminalChrome.terminal_surface_pane_id(panes, %{}, "%2", nil) == "%2"
    end

    test "falls back to the first operator pane when preview is active and previous is missing" do
      panes = [
        %{id: "%1", active: false},
        %{id: "%2", active: true}
      ]

      preview_panes = %{"%2" => %{pane_id: "%2"}}

      assert TerminalChrome.terminal_surface_pane_id(panes, preview_panes, "%2", nil) == "%1"
    end

    test "moves to fallback when the sticky pane is gone" do
      panes = [
        %{id: "%2", active: true}
      ]

      assert TerminalChrome.terminal_surface_pane_id(panes, %{}, "%2", "%1") == "%2"
    end
  end
end
