defmodule DevIdeWeb.WorkspaceLive.TerminalSurfaceTest do
  use DevIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

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

  describe "preview_snapshot_mode?/1" do
    test "detects fitted artifact preview URLs" do
      assert TerminalChrome.preview_snapshot_mode?(%{
               display_url: "https://devide.example.test/preview-artifacts/ws/1.png?fit=preview"
             })
    end

    test "leaves trusted iframe URLs interactive" do
      refute TerminalChrome.preview_snapshot_mode?(%{display_url: "http://localhost:5173/"})
    end
  end

  describe "pane_resize_handles/1" do
    test "renders overlay-scoped resize handles for preview panes" do
      html =
        render_component(&TerminalChrome.pane_resize_handles/1,
          pane_id: "%2",
          prefix: "preview-pane",
          z_class: "z-30"
        )

      assert html =~ ~s(id="preview-pane-drag-left--2")
      assert html =~ ~s(id="preview-pane-drag-right--2")
      assert html =~ ~s(id="preview-pane-drag-up--2")
      assert html =~ ~s(id="preview-pane-drag-down--2")
      assert html =~ ~s(data-tmux-resize-handle="true")
      assert html =~ ~s(data-pane-id="%2")
      assert html =~ ~s(data-resize-axis="x")
      assert html =~ ~s(data-resize-axis="y")
      assert html =~ "z-30"
    end
  end
end
