defmodule DevIDE.Terminals.PaneStateTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Terminals.PaneState

  @spinner <<0x2802::utf8>>
  @ready <<0x2733::utf8>>

  test "detects working Claude titles from Braille spinner glyphs" do
    title = @spinner <> " Improve agent state detection"

    assert PaneState.from_title(title) == :working
    assert PaneState.task_summary(title) == "Improve agent state detection"
  end

  test "detects ready Claude titles and extracts the task summary" do
    title = @ready <> " Review patch"

    assert PaneState.from_title(title) == :ready
    assert PaneState.task_summary(title) == "Review patch"
  end

  test "classifies by leading marker only" do
    title = @ready <> " Fix " <> @spinner <> " spinner glyph rendering"

    assert PaneState.from_title(title) == :ready
    assert PaneState.task_summary(title) == "Fix " <> @spinner <> " spinner glyph rendering"
    assert PaneState.from_title("Fix " <> @ready <> " ready marker docs") == :unknown
    assert PaneState.from_title("Fix " <> @spinner <> " spinner glyph rendering") == :unknown
  end

  test "enriches topology panes and windows with derived state" do
    topology = %{
      session: "tmux",
      panes: [
        %{
          id: "%1",
          window_id: "@1",
          index: 0,
          active: true,
          role: "agent",
          pane_title: @ready <> " Ship title state"
        }
      ],
      windows: [
        %{id: "@1", index: 0, name: "claude", active: true, panes: 1, pane_list: [%{id: "%1"}]}
      ]
    }

    assert %{
             panes: [%{pane_state: :ready, task_summary: "Ship title state"}],
             windows: [%{pane_state: :ready, task_summary: "Ship title state"}]
           } = PaneState.enrich_topology(topology)
  end
end
