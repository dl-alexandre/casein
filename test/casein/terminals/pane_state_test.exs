defmodule Casein.Terminals.PaneStateTest do
  use Casein.TestCase, async: true

  alias Casein.Terminals.PaneState

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

  test "detects working Grok titles from Braille spinner glyphs" do
    title = @spinner <> " - Thinking - … - grok"

    assert PaneState.from_title(title) == :working
  end

  test "classifies plain idle Grok titles as unknown" do
    title = "Add Grok pane title tests - grok"

    assert PaneState.from_title(title) == :unknown
  end

  test "Grok task_summary strips Braille spinner prefixes" do
    title = @spinner <> " Add Grok pane title tests - grok"

    assert PaneState.task_summary(title) == "Add Grok pane title tests - grok"
  end

  test "classifies by leading marker only" do
    title = @ready <> " Fix " <> @spinner <> " spinner glyph rendering"

    assert PaneState.from_title(title) == :ready
    assert PaneState.task_summary(title) == "Fix " <> @spinner <> " spinner glyph rendering"
    assert PaneState.from_title("Fix " <> @ready <> " ready marker docs") == :unknown
    assert PaneState.from_title("Fix " <> @spinner <> " spinner glyph rendering") == :unknown
  end

  test "task summary rejects the tmux default hostname title" do
    {:ok, hostname} = :inet.gethostname()

    assert PaneState.task_summary(List.to_string(hostname)) == nil
    assert PaneState.task_summary("Review project health audit") == "Review project health audit"
  end

  test "task summary rejects UUID agent session titles" do
    assert PaneState.task_summary("019f9c65-25cc-7353-b7a0-ffe0d65e7952") == nil
  end

  test "task summary rejects bare runtime banners with no real task" do
    assert PaneState.task_summary("OpenCode") == nil
    assert PaneState.task_summary("Claude Code") == nil
    assert PaneState.task_summary(@ready <> " Claude Code") == nil
    assert PaneState.task_summary("Codex") == nil
    assert PaneState.task_summary("Ship fleet chrome") == "Ship fleet chrome"
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

  defp window_with(panes) do
    %{id: "@1", index: 0, name: "factory_manager", active: true, pane_list: panes}
  end

  describe "preview panes do not become the window's identity (#20029)" do
    test "a preview URL title is not a task summary" do
      # It is the preview surface naming itself, in the same class as the
      # hostname and bare runtime titles this module already rejects.
      refute PaneState.task_summary("preview http://localhost:21012/")
      refute PaneState.task_summary("preview http://localhost:21012/login")
      refute PaneState.task_summary("preview https://example.com")
    end

    test "a task summary that merely starts with the word preview survives" do
      # The URL is what makes it chrome. Requiring it is the whole guard
      # against swallowing real work orders.
      assert PaneState.task_summary("Preview the new dashboard layout") ==
               "Preview the new dashboard layout"

      assert PaneState.task_summary("preview mode for time pickers") ==
               "preview mode for time pickers"
    end

    test "an active preview pane does not displace the working pane" do
      # The reported shape: the auto-created preview is active, the agent is
      # not, and neither carries a role tag.
      window =
        window_with([
          %{id: "%17", active: false, pane_title: "Time pickers — default 12:00 AM"},
          %{id: "%63", active: true, pane_title: "preview http://localhost:21012/"}
        ])

      assert %{id: "%17"} = PaneState.agent_or_active_pane(window)
      assert PaneState.window_task_summary(window) == "Time pickers — default 12:00 AM"
    end

    test "a preview pane listed first does not win the first-pane fallback" do
      window =
        window_with([
          %{id: "%64", active: false, pane_title: "preview http://localhost:21027/"},
          %{id: "%54", active: false, pane_title: "Add six token families"}
        ])

      assert %{id: "%54"} = PaneState.agent_or_active_pane(window)
      assert PaneState.window_task_summary(window) == "Add six token families"
    end

    test "the role tag still wins, even over a non-preview active pane" do
      window =
        window_with([
          %{id: "%1", active: true, pane_title: "some shell"},
          %{id: "%2", active: false, role: "agent", pane_title: "Real work order"}
        ])

      assert %{id: "%2"} = PaneState.agent_or_active_pane(window)
    end

    test "a window of nothing but preview panes still resolves to one" do
      # This narrows what wins a tie; it must not turn an answer into nil.
      window = window_with([%{id: "%9", active: true, pane_title: "preview http://localhost:1/"}])

      assert %{id: "%9"} = PaneState.agent_or_active_pane(window)
    end

    test "preview_pane?/1 reads the title and tolerates a missing one" do
      assert PaneState.preview_pane?(%{pane_title: "preview http://localhost:21012/"})
      assert PaneState.preview_pane?(%{pane_title: "  preview http://localhost:21012/  "})
      refute PaneState.preview_pane?(%{pane_title: "Preview the new dashboard"})
      refute PaneState.preview_pane?(%{id: "%1"})
      refute PaneState.preview_pane?(nil)
    end
  end
end
