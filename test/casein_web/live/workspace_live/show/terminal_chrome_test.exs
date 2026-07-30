defmodule CaseinWeb.WorkspaceLive.Show.TerminalChromeTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CaseinWeb.WorkspaceLive.Show.TerminalChrome

  describe "preview_proxied?/1" do
    test "true only for /preview-proxy/ display URLs" do
      assert TerminalChrome.preview_proxied?(%{display_url: "/preview-proxy/ws/3000/"})
      assert TerminalChrome.preview_proxied?(%{"display_url" => "/preview-proxy/ws/3000/app"})
      refute TerminalChrome.preview_proxied?(%{display_url: "http://localhost:3000/"})
      refute TerminalChrome.preview_proxied?(%{display_url: "/preview-artifacts/ws/x.png"})
      refute TerminalChrome.preview_proxied?(%{})
    end
  end

  describe "preview_snapshot_mode?/1 and preview_playback_mode?/1" do
    test "a PNG snapshot artifact is snapshot mode, not playback" do
      png = %{display_url: "https://app/preview-artifacts/ws/7.png?fit=preview"}
      assert TerminalChrome.preview_snapshot_mode?(png)
      refute TerminalChrome.preview_playback_mode?(png)
    end

    test "a webm recording is playback mode, not snapshot (so video controls stay clickable)" do
      webm = %{display_url: "https://app/preview-artifacts/ws/rec.webm?fit=playback"}
      assert TerminalChrome.preview_playback_mode?(webm)
      refute TerminalChrome.preview_snapshot_mode?(webm)
    end

    test "a live app URL is neither" do
      live = %{display_url: "http://localhost:3000/"}
      refute TerminalChrome.preview_snapshot_mode?(live)
      refute TerminalChrome.preview_playback_mode?(live)
    end
  end

  describe "data-snapshot-mode rendered attribute (#163 / HEEx boolean attrs)" do
    # Regression: HEEx encodes bare `true` as a *valueless* attribute and omits
    # `false`, so `dataset.snapshotMode === "true"` in preview_pane_overlay.js is
    # always false unless the attr is wrapped in to_string/1. Predicate unit
    # tests alone cannot catch this — they never see the markup.
    test "snapshot artifact renders data-snapshot-mode=\"true\", not the valueless form" do
      html =
        render_preview_overlay(%{
          display_url: "https://app/preview-artifacts/ws/7.png?fit=preview"
        })

      assert html =~ ~s(data-snapshot-mode="true")
      # Valueless encoding is `data-snapshot-mode` with no `=value` (space or tag end).
      refute html =~ ~r/data-snapshot-mode[\s>\/]/
    end

    test "live iframe preview renders data-snapshot-mode=\"false\"" do
      html = render_preview_overlay(%{display_url: "http://localhost:3000/"})

      assert html =~ ~s(data-snapshot-mode="false")
    end
  end

  describe "preview_iframe_sandbox/1" do
    test "proxied previews keep allow-same-origin for authenticated proxy loads" do
      sandbox = TerminalChrome.preview_iframe_sandbox(%{display_url: "/preview-proxy/ws/3000/"})

      assert sandbox =~ "allow-same-origin"
      assert sandbox =~ "allow-scripts"
    end

    test "direct/snapshot previews keep allow-same-origin" do
      assert TerminalChrome.preview_iframe_sandbox(%{display_url: "http://localhost:3000/"}) =~
               "allow-same-origin"

      assert TerminalChrome.preview_iframe_sandbox(%{display_url: "/preview-artifacts/ws/x.png"}) =~
               "allow-same-origin"
    end
  end

  defp render_preview_overlay(preview) do
    render_component(&TerminalChrome.tmux_pane_geometry/1,
      workspace: %{id: "ws-chrome-attr"},
      active_tmux_window_panes: [
        %{
          id: "%2",
          index: 0,
          active: true,
          left: 0,
          top: 0,
          width: 80,
          height: 24,
          window_id: "@0",
          current_path: "/tmp",
          current_command: "bash"
        }
      ],
      preview_panes: %{"%2" => Map.put(preview, :pane_id, "%2")},
      tmux_session: "casein_ws_chrome",
      ui_highlight_pane_id: "%2",
      tmux_active_pane_id: "%2",
      tmux_mutations_enabled?: false,
      entered_preview_pane_id: nil,
      terminal_surface_pane_id: nil
    )
  end
end
