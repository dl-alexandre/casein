defmodule CaseinWeb.WorkspaceLive.TerminalSurfaceTest do
  use CaseinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome

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

  describe "renderable_tmux_window_panes/1" do
    test "collapses a zoomed window to the active zoomed pane geometry" do
      panes = [
        %{id: "%1", index: 0, active: false, left: 0, top: 0, width: 40, height: 24},
        %{
          id: "%2",
          index: 1,
          active: true,
          left: 40,
          top: 0,
          width: 40,
          height: 24,
          zoomed?: true
        }
      ]

      assert [
               %{
                 id: "%2",
                 active: true,
                 left: 0,
                 top: 0,
                 width: 80,
                 height: 24,
                 zoomed?: true
               }
             ] = TerminalChrome.renderable_tmux_window_panes(panes)
    end

    test "keeps split geometry when no pane is zoomed" do
      panes = [
        %{id: "%1", index: 0, active: true, left: 0, top: 0, width: 40, height: 24},
        %{id: "%2", index: 1, active: false, left: 40, top: 0, width: 40, height: 24}
      ]

      assert TerminalChrome.renderable_tmux_window_panes(panes) == panes
    end
  end

  describe "preview_snapshot_mode?/1" do
    test "detects fitted artifact preview URLs" do
      assert TerminalChrome.preview_snapshot_mode?(%{
               display_url: "https://casein.example.test/preview-artifacts/ws/1.png?fit=preview"
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

  describe "tmux_pane_geometry/1 preview ownership" do
    test "does not render per-pane scrollback HUD buttons" do
      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha"},
          active_tmux_window_panes: [pane("%1")],
          preview_panes: %{},
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%1",
          tmux_active_pane_id: "%1",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: nil
        )

      refute html =~ "pane-history-open"
      refute html =~ ~s(phx-click="pane:history_open")
    end

    test "renders preview pane owning tmux session metadata" do
      tmux_session = "casein_alpha_u-agent-worktree"

      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha"},
          active_tmux_window_panes: [pane("%2")],
          preview_panes: %{
            "%2" => %{
              pane_id: "%2",
              display_url: "http://localhost:5173/",
              tmux_session: tmux_session
            }
          },
          tmux_session: tmux_session,
          ui_highlight_pane_id: "%2",
          tmux_active_pane_id: "%2",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: nil
        )

      assert html =~ ~s(data-preview-tmux-session="#{tmux_session}")
      assert html =~ ~s(data-active-tmux-session="#{tmux_session}")
      assert html =~ ~s(data-preview-session-mismatch="false")
      assert html =~ ~s(data-preview-status)
      assert html =~ ~s(data-preview-reload)
      assert html =~ ~s(data-preview-reopen)
      assert html =~ "Session worktree"
    end

    test "marks a preview pane from another tmux session" do
      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha"},
          active_tmux_window_panes: [pane("%2")],
          preview_panes: %{
            "%2" => %{
              pane_id: "%2",
              display_url: "http://localhost:5173/",
              tmux_session: "casein_alpha_u-other"
            }
          },
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%2",
          tmux_active_pane_id: "%2",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: nil
        )

      assert html =~ ~s(data-preview-session-mismatch="true")
      assert html =~ "Other session: u-other"
      assert html =~ "active tmux_session=casein_alpha_u-active"
    end

    test "renders mobile focus state and spatial pane rails" do
      panes = [
        %{pane("%0") | index: 0, active: true, left: 0, top: 0, width: 50, height: 40},
        %{pane("%1") | index: 1, active: false, left: 50, top: 0, width: 50, height: 20},
        %{pane("%2") | index: 2, active: false, left: 50, top: 20, width: 50, height: 20}
      ]

      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha", status: :running},
          active_tmux_window_panes: panes,
          preview_panes: %{},
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%0",
          tmux_active_pane_id: "%0",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: "%0",
          focused_pane_id: "pane-1",
          pane_data: %{}
        )

      assert html =~ ~s(data-mobile-focus-layout="true")
      assert html =~ ~s(data-mobile-focus-pane-id="%0")
      assert html =~ "--casein-mobile-pane-left: 0.0%"
      # Active pane is full-height/half-width -> uniform (min) scale is 1.0, not a
      # 2.0 horizontal stretch.
      assert html =~ "--casein-mobile-pane-scale: 1.0"
      assert html =~ ~s(data-terminal-surface-mount="true")
      assert html =~ ~s(id="tmux-pane--0")
      assert html =~ ~s(data-mobile-pane-active="true")
      assert html =~ ~s(data-mobile-pane-rail="right")
      assert html =~ ~s(phx-value-pane-id="%1")
      assert html =~ ~s(phx-value-pane-id="%2")
      assert html =~ "top: 50.0%; height: 50.0%"
    end

    test "keeps the focus layout and pane rails when the active pane is zoomed" do
      # tmux-zoom collapses the rendered surface to the single zoomed pane, but the
      # rails (and multi-pane detection) must survive so the user can still switch
      # panes — otherwise a zoomed window is indistinguishable from a single pane.
      panes = [
        %{pane("%0") | index: 0, active: true, left: 0, top: 0, width: 50, height: 40}
        |> Map.put(:zoomed?, true),
        %{pane("%1") | index: 1, active: false, left: 50, top: 0, width: 50, height: 20},
        %{pane("%2") | index: 2, active: false, left: 50, top: 20, width: 50, height: 20}
      ]

      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha", status: :running},
          active_tmux_window_panes: panes,
          preview_panes: %{},
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%0",
          tmux_active_pane_id: "%0",
          window_zoomed?: true,
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: "%0",
          focused_pane_id: "pane-1",
          pane_data: %{}
        )

      # Focus layout stays on and the zoom flag is exposed to the client hook.
      assert html =~ ~s(data-mobile-focus-layout="true")
      assert html =~ ~s(data-window-zoomed="true")
      # Surface collapsed to the single zoomed pane...
      assert html =~ ~s(id="tmux-pane--0")
      refute html =~ ~s(id="tmux-pane--1")
      # ...but the rails to the other panes still render.
      assert html =~ ~s(data-mobile-pane-rail="right")
      assert html =~ ~s(phx-value-pane-id="%1")
      assert html =~ ~s(phx-value-pane-id="%2")
    end
  end

  describe "tmux_pane_geometry/1 pane history drawer" do
    test "renders a non-modal drawer with refresh and latest controls" do
      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha"},
          active_tmux_window_panes: [pane("%3")],
          preview_panes: %{},
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%3",
          tmux_active_pane_id: "%3",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: nil,
          pane_history: %{
            key: "casein_alpha_u-active:@1:%3",
            session: "casein_alpha_u-active",
            window_id: "@1",
            pane_id: "%3",
            title: "/work/casein · bash",
            term: nil,
            cols: 80,
            rows: 24,
            refreshed_at: 1
          }
        )

      assert html =~ ~s(id="pane-history-drawer")
      assert html =~ ~s(phx-hook="PaneHistoryDrawer")
      assert html =~ ~s(data-history-key="casein_alpha_u-active:@1:%3")
      assert html =~ ~s(phx-click="pane:history_open")
      assert html =~ ~s(phx-value-pane-id="%3")
      assert html =~ ~s(data-history-latest)
      assert html =~ "Loading scrollback"
      refute html =~ "pane-history-modal"
    end
  end

  describe "tmux_pane_geometry/1 pairing badge" do
    test "renders unpaired badge only for panes stamped @casein_paired=0" do
      unpaired = Map.merge(pane("%1"), %{paired: false, paired_reason: "no agent env"})

      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha"},
          active_tmux_window_panes: [unpaired],
          preview_panes: %{},
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%1",
          tmux_active_pane_id: "%1",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: nil
        )

      assert html =~ ~s(data-pane-paired="false")
      assert html =~ ~s(data-role="pane-unpaired-badge")
      assert html =~ "Agent launched without Casein MCP — no agent env"
    end

    test "renders no badge for paired or never-launched panes" do
      paired = Map.put(pane("%1"), :paired, true)

      html =
        render_component(&TerminalChrome.tmux_pane_geometry/1,
          workspace: %{id: "ws-alpha"},
          active_tmux_window_panes: [paired, Map.put(pane("%2"), :id, "%2")],
          preview_panes: %{},
          tmux_session: "casein_alpha_u-active",
          ui_highlight_pane_id: "%1",
          tmux_active_pane_id: "%1",
          tmux_mutations_enabled?: false,
          entered_preview_pane_id: nil,
          terminal_surface_pane_id: nil
        )

      assert html =~ ~s(data-pane-paired="true")
      refute html =~ ~s(data-role="pane-unpaired-badge")
    end
  end

  defp pane(id) do
    %{
      id: id,
      index: 0,
      active: true,
      left: 0,
      top: 0,
      width: 80,
      height: 24,
      window_id: "@0",
      current_path: "/work/casein",
      current_command: "bash"
    }
  end
end
