defmodule DevIdeWeb.WorkspaceLive.Show.TerminalStateTest do
  use ExUnit.Case, async: true

  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  describe "next_ui_highlight_pane_id/5" do
    # A preview tile the user clicked in window @1 stays highlighted across an
    # activity-only refresh (no window change), so its titlebar/selection holds.
    test "keeps a selected preview tile when the window has not changed" do
      preview_panes = %{"%preview" => %{}}

      assert "%preview" =
               TerminalState.next_ui_highlight_pane_id(
                 "%preview",
                 "%op",
                 "%op",
                 preview_panes,
                 false
               )
    end

    # The bug: switching to window @2 must re-seat the highlight on @2's active
    # pane instead of stranding @1's preview tile (which leaves @2 with nothing
    # highlighted and the preview titlebar lingering).
    test "snaps to the new window's active pane on a window switch" do
      preview_panes = %{"%preview" => %{}}

      assert "%w2-active" =
               TerminalState.next_ui_highlight_pane_id(
                 "%preview",
                 "%w2-active",
                 "%w1-active",
                 preview_panes,
                 true
               )
    end

    test "seeds the highlight from the active pane when none is set yet" do
      assert "%op" =
               TerminalState.next_ui_highlight_pane_id(nil, "%op", "%op", %{}, false)
    end

    test "follows tmux focus when the highlight was tracking the active pane" do
      assert "%new" =
               TerminalState.next_ui_highlight_pane_id("%old", "%new", "%old", %{}, false)
    end

    test "holds a non-tracking selection when tmux focus moves within the window" do
      assert "%pinned" =
               TerminalState.next_ui_highlight_pane_id("%pinned", "%new", "%old", %{}, false)
    end
  end

  describe "selected_preview_pane/6" do
    @windows [
      %{
        id: "@1",
        active: true,
        pane_list: [%{id: "%shell"}, %{id: "%preview"}]
      },
      %{
        id: "@2",
        active: false,
        pane_list: [%{id: "%other"}]
      }
    ]

    @preview_panes %{
      "%preview" => %{
        pane_id: "%preview",
        title: "Docs",
        display_url: "https://example.com/docs",
        tmux_session: "devide_alpha_u-alice"
      }
    }

    test "returns nil when highlight points at a preview in another window" do
      assert TerminalState.selected_preview_pane(
               @preview_panes,
               nil,
               "%preview",
               @windows,
               "@2",
               "devide_alpha_u-alice"
             ) == nil
    end

    test "returns nil when pane id matches another tmux session's preview" do
      other_session_preview = %{
        "%preview" => %{
          pane_id: "%preview",
          title: "Stale",
          display_url: "https://example.com/stale",
          tmux_session: "devide_alpha_u-bob"
        }
      }

      assert TerminalState.selected_preview_pane(
               other_session_preview,
               "%preview",
               nil,
               @windows,
               "@1",
               "devide_alpha_u-alice"
             ) == nil
    end

    test "returns the preview when it belongs to the active window and session" do
      assert %{
               title: "Docs",
               display_url: "https://example.com/docs"
             } =
               TerminalState.selected_preview_pane(
                 @preview_panes,
                 "%preview",
                 nil,
                 @windows,
                 "@1",
                 "devide_alpha_u-alice"
               )
    end
  end
end
