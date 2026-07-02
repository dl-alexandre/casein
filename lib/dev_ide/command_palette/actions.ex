defmodule DevIDE.CommandPalette.Actions do
  @moduledoc """
  Fixed allowlist of command palette actions.

  Each action carries a payload that names an existing LiveView event the
  Show LiveView already handles (`switch_tab`, `run:start`, `tree:refresh`,
  `isolation:refresh`, `terminal:set_mode`,
  `terminal:toggle_chrome`, fixed tmux verbs such as
  `tmux:consolidate_sessions`, and the structural pane verbs `split_right`,
  `split_down`, `equalize_layout`, `pane:close_focused`,
  `pane:close_others`, `pane:cycle_layout`, `pane:focus_next`,
  `pane:focus_previous`, and `pane:zoom_focused`). The palette never
  invents new mutation events; it only routes to gated existing ones, and it
  never sends arbitrary keystrokes to a pane.
  """

  alias DevIDE.Commands.Allowlist
  alias DevIDE.CommandPalette.Item
  alias DevIDE.Terminals.Theme

  @tabs ~w(terminal files search diff run agents logs)

  # Internal test hooks — still on the exec allowlist but never palette-listed.
  @palette_hidden_commands ~w(dogfood.fail)

  @spec all() :: [Item.t()]
  def all do
    tab_items() ++
      command_items() ++
      tmux_items() ++ theme_items() ++ agents_items() ++ refresh_items() ++ preview_items()
  end

  defp tab_items do
    Enum.map(@tabs, fn tab ->
      %Item{
        id: "tab:" <> tab,
        kind: :tab,
        label: "Open tab: " <> tab,
        detail: "switch to " <> tab,
        keywords: ["go to " <> tab, "show " <> tab, "view"],
        payload: %{event: "switch_tab", params: %{"tab" => tab}}
      }
    end)
  end

  defp command_items do
    Allowlist.all()
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reject(&(&1 in @palette_hidden_commands))
    |> Enum.map(&command_item/1)
  end

  defp command_item(id) do
    {:ok, argv} = Allowlist.argv_for(id)
    cmd = Enum.join(argv, " ")

    %Item{
      id: "command:" <> id,
      kind: :command,
      label: cmd,
      detail: cmd,
      keywords: ["run " <> id],
      payload: %{event: "run:start", params: %{"id" => id}}
    }
  end

  # Structural tmux/pane verbs. Each routes to an existing param-less LiveView
  # event that operates on the focused pane / whole layout — no arbitrary
  # keystrokes are ever sent (that would breach the "no free-form mutation"
  # invariant). Kept under the Tmux category tab. Terminal mode/chrome entries
  # keep `kind: :action` (LV-side filtering and tests key off the id) but ride
  # in the Tmux tab via the explicit `category`.
  defp tmux_items do
    [
      %Item{
        id: "tmux:new_window",
        kind: :action,
        category: :tmux,
        label: "New tmux window",
        detail: "Create a window in the active session",
        keywords: ["create window", "window tab"],
        payload: %{event: "tmux:new_window", params: %{}}
      },
      %Item{
        id: "tmux:last_window",
        kind: :action,
        category: :tmux,
        label: "Last tmux window",
        detail: "Toggle back to the previous window",
        keywords: ["previous window", "toggle window", "back"],
        payload: %{event: "tmux:last_window", params: %{}}
      },
      %Item{
        id: "tmux:consolidate_sessions",
        kind: :action,
        category: :tmux,
        label: "Consolidate session",
        detail: "Move this workspace's other sessions into the active session as windows",
        keywords: ["merge sessions", "gather windows", "combine"],
        payload: %{event: "tmux:consolidate_sessions", params: %{}}
      },
      %Item{
        id: "tmux:split_right",
        kind: :action,
        category: :tmux,
        label: "Split Horizontal",
        detail: "New pane beside the focused one",
        # vim/VS Code users call a side-by-side split "vertical" — index both.
        keywords: ["split right", "vertical split", "vsplit", "side by side", "pane beside"],
        payload: %{event: "split_right", params: %{}}
      },
      %Item{
        id: "tmux:split_down",
        kind: :action,
        category: :tmux,
        label: "Split Vertical",
        detail: "New pane below the focused one",
        keywords: ["split down", "horizontal split", "hsplit", "split below", "stack panes"],
        payload: %{event: "split_down", params: %{}}
      },
      %Item{
        id: "tmux:next_pane",
        kind: :action,
        category: :tmux,
        label: "Next Pane",
        detail: "Focus the next pane in layout order",
        keywords: ["focus next", "cycle panes"],
        payload: %{event: "pane:focus_next", params: %{}}
      },
      %Item{
        id: "tmux:previous_pane",
        kind: :action,
        category: :tmux,
        label: "Previous Pane",
        detail: "Focus the previous pane in layout order",
        keywords: ["focus previous", "back pane"],
        payload: %{event: "pane:focus_previous", params: %{}}
      },
      %Item{
        id: "tmux:zoom",
        kind: :action,
        category: :tmux,
        label: "Zoom / Unzoom",
        detail: "Toggle the focused pane full-size",
        keywords: ["fullscreen pane", "maximize pane", "restore pane"],
        payload: %{event: "pane:zoom_focused", params: %{}}
      },
      %Item{
        id: "tmux:cycle_layout",
        kind: :action,
        category: :tmux,
        label: "Cycle Pane Layout",
        detail: "Rotate split direction for the workspace pane tree",
        keywords: ["rotate layout", "arrange panes"],
        payload: %{event: "pane:cycle_layout", params: %{}}
      },
      %Item{
        id: "tmux:equalize",
        kind: :action,
        category: :tmux,
        label: "Equalize Pane Sizes",
        detail: "Reset every split to uniform ratios",
        keywords: ["balance panes", "resize panes", "even splits"],
        payload: %{event: "equalize_layout", params: %{}}
      },
      %Item{
        id: "tmux:close_pane",
        kind: :action,
        category: :tmux,
        label: "Close Pane",
        detail: "Kill the focused pane's tmux session",
        keywords: ["kill pane", "quit pane"],
        payload: %{event: "pane:close_focused", params: %{}}
      },
      %Item{
        id: "tmux:close_other_panes",
        kind: :action,
        category: :tmux,
        label: "Close Other Panes",
        detail: "Keep the focused pane and close the rest",
        keywords: ["kill others", "only pane"],
        payload: %{event: "pane:close_others", params: %{}}
      },
      # Terminals are always raw; this entry (re)focuses the raw surface.
      %Item{
        id: "action:terminal:raw",
        kind: :action,
        category: :tmux,
        label: "Terminal: raw shell",
        detail: "Full local PTY",
        keywords: ["pty", "console", "bash"],
        payload: %{event: "terminal:set_mode", params: %{"mode" => "raw"}}
      },
      %Item{
        id: "action:terminal:toggle_chrome",
        kind: :action,
        category: :tmux,
        label: "Terminal: toggle focus mode (hide/show chrome)",
        detail: "Maximize terminal space — hides header and utility bar",
        keywords: [
          "fullscreen",
          "zen mode",
          "distraction free",
          "hide header",
          "maximize terminal"
        ],
        payload: %{event: "terminal:toggle_chrome", params: %{}}
      }
    ]
  end

  defp theme_items do
    Enum.map(Theme.list_presets(), fn preset ->
      %Item{
        id: "terminal:theme:" <> preset.id,
        kind: :action,
        category: :tmux,
        label: "Terminal theme: " <> preset.label,
        detail: preset.detail,
        keywords: ["color scheme", "colors", "appearance"],
        payload: %{event: "terminal:set_preset", params: %{"preset" => preset.id}}
      }
    end)
  end

  defp refresh_items do
    [
      %Item{
        id: "action:tree:refresh",
        kind: :action,
        label: "Refresh file tree",
        keywords: ["reload files", "rescan tree"],
        payload: %{event: "tree:refresh", params: %{}}
      },
      %Item{
        id: "action:isolation:refresh",
        kind: :action,
        label: "Refresh DB isolation",
        keywords: ["database", "postgres", "sandbox"],
        payload: %{event: "isolation:refresh", params: %{}}
      }
    ]
  end

  defp agents_items do
    [
      %Item{
        id: "agents:apply_pair",
        kind: :action,
        category: :agents,
        label: "Apply agent pair layout",
        detail: "Operator, agent, and verify panes",
        keywords: ["template", "operator pane", "verify pane"],
        payload: %{event: "tmux:apply_template", params: %{"template-id" => "agent_pair"}}
      },
      %Item{
        id: "audit:drawer",
        kind: :action,
        category: :agents,
        label: "Open audit drawer",
        detail: "Inspect recent workspace events",
        keywords: ["events", "history", "activity log"],
        payload: %{event: "audit_drawer:toggle", params: %{}}
      }
    ]
  end

  @doc "Allowlist of LiveView events the palette is permitted to dispatch."
  def allowed_events do
    MapSet.new([
      "switch_tab",
      "run:start",
      "tree:refresh",
      "isolation:refresh",
      "annotation:open",
      "attach_terminal_session",
      "terminal:set_mode",
      "terminal:switch_to_shell",
      "terminal:toggle_chrome",
      "terminal:set_preset",
      "tmux:new_window",
      "tmux:last_window",
      "tmux:consolidate_sessions",
      "tmux:select_window",
      "tmux:select_pane",
      "tmux:apply_template",
      "tmux:preview_template",
      "audit_drawer:toggle",
      "split_right",
      "split_down",
      "equalize_layout",
      "pane:close_focused",
      "pane:close_others",
      "pane:cycle_layout",
      "pane:focus_next",
      "pane:focus_previous",
      "pane:zoom_focused",
      "preview:open",
      "preview:close"
    ])
  end

  defp preview_items do
    [
      %Item{
        id: "preview:open-url",
        kind: :action,
        category: :preview,
        label: "Preview: Open URL",
        detail: "Open a browser preview panel",
        keywords: ["browser", "web", "localhost"],
        payload: %{
          event: "preview:open",
          params: %{"url" => "http://localhost:4000", "mode" => "tab"}
        }
      },
      %Item{
        id: "preview:open-dev-server",
        kind: :action,
        category: :preview,
        label: "Preview: Open Current Dev Server",
        detail: "Detect port from recent pane/session metadata and open localhost preview",
        keywords: ["browser", "localhost", "port"],
        payload: %{
          event: "preview:open",
          params: %{"source" => "detected", "mode" => "tab"}
        }
      }
    ]
  end
end
