defmodule CaseinWeb.WorkspaceLive.Show.LeaderBindings do
  @moduledoc """
  The `C-b` leader keymap, as data.

  The binding for an action was restated in five places, none of which could
  see the others:

    * `assets/js/workspace_leader_election.mjs` — a literal `LEADER_ACTIONS`
      object, the only copy that actually dispatched.
    * `Casein.CommandPalette.Actions` — `hint: "C-b z"` strings on 9 items.
    * `Show.PaletteItems` — 3 more hints on dynamic items.
    * `Show.LeaderHelp` — a hand-written cheatsheet.
    * `Show.SessionBar` — `data-leader-second-key` glyphs on visible chrome.

  They had already drifted: `{` and `}` (pane swap) dispatched and carried
  palette hints, but no cheatsheet row ever documented them.

  Now the keymap is defined once here and everything else reads it: the browser
  gets `key_map/0` serialized onto the hook element, the palette gets
  `hint_for/1`, and the cheatsheet renders `groups/0`. A rebinding is one edit.

  ## Why the web tier and not the domain

  A keybinding is presentation. `CommandPalette.Actions` (domain) stays the
  authority on what an action *is* and whether it may run; this module only says
  which key reaches it. That split is also what the boundary requires — the
  domain may not depend on `CaseinWeb` — so palette hints are decorated onto
  items here rather than baked into the catalog.

  ## Scope

  Only the `C-b` second-key map lives here. The session/window picker keys
  (`SessionPicker`), the global chords (`Ctrl+P`, `Ctrl/Cmd+Shift+F`), and the
  in-palette keys are separate keymaps owned by their own hooks; the cheatsheet
  still documents those as prose.

  ## Entry shape

  `keys` and `actions` line up in one of two ways:

    * one action, many keys → every key is a synonym (`%` and `|` both split
      right);
    * equal lengths → positional (`n`→next-window, `p`→prev-window).

  An entry with no keys (`0-9`, `Esc`) is documentation only: it appears in the
  cheatsheet but dispatches through its own path in the hook.

  `target` records where the key lands, which is what `dispatch_actions/0`
  reports so tests can assert the shell still renders a button for each:

    * `:dispatch` — a hidden `[data-leader-action]` button in `WorkspaceShell`
    * `:picker` — the session/window dropdown `<summary>` (needs visible chrome)
    * `:client` — handled entirely in the hook, with no server round trip
  """

  @groups [
    %{id: :sessions, label: "Sessions & windows"},
    %{id: :panes, label: "Panes"},
    %{id: :more, label: "More leader keys"}
  ]

  @bindings [
    # --- Sessions & windows ---------------------------------------------------
    %{
      keys: ["s"],
      actions: ["session-picker"],
      target: :picker,
      group: :sessions,
      display: "s",
      desc: "pick a session"
    },
    %{
      keys: ["w"],
      actions: ["window-picker"],
      target: :picker,
      group: :sessions,
      display: "w",
      desc: "pick a window"
    },
    %{
      keys: ["(", ")"],
      actions: ["prev-session", "next-session"],
      target: :dispatch,
      group: :sessions,
      display: "( / )",
      desc: "previous or next session"
    },
    %{
      keys: ["c"],
      actions: ["new-window"],
      target: :dispatch,
      group: :sessions,
      display: "c",
      desc: "open a new window",
      palette_ids: ["tmux:new_window"]
    },
    %{
      keys: ["C"],
      actions: ["new-window-tab"],
      target: :dispatch,
      group: :sessions,
      display: "C",
      desc: "new window in a new browser tab"
    },
    %{
      keys: ["n", "p"],
      actions: ["next-window", "prev-window"],
      target: :dispatch,
      group: :sessions,
      display: "n / p",
      desc: "next or previous window"
    },
    %{
      keys: ["l"],
      actions: ["last-window"],
      target: :dispatch,
      group: :sessions,
      display: "l",
      desc: "jump back to your last window",
      palette_ids: ["tmux:last_window"]
    },
    # Attention-aware jump. `a` was unbound in tmux and in Casein (checked
    # against key_map/0 — the gate test below asserts no key is claimed twice).
    # Cycles the FleetBoard `needs_you?` rows, the same set the fleet badge
    # counts; see FleetBoard.needs_you_rows/1 for why a stalled-but-not-asking
    # pane is not a target.
    %{
      keys: ["a"],
      actions: ["jump-needs-you"],
      target: :dispatch,
      group: :sessions,
      display: "a",
      desc: "jump to the next pane that needs you"
    },
    %{
      keys: [],
      actions: [],
      target: :client,
      group: :sessions,
      display: "0–9",
      desc: "jump to window 0–9"
    },
    # The rename items carry a dynamic id suffix (`rename:window:<id>`), so they
    # look their hint up by action name via `hint_for_action/1` instead.
    %{
      keys: [","],
      actions: ["rename-window"],
      target: :dispatch,
      group: :sessions,
      display: ",",
      desc: "rename this window"
    },
    %{
      keys: ["$"],
      actions: ["rename-session"],
      target: :dispatch,
      group: :sessions,
      display: "$",
      desc: "rename this session"
    },
    %{
      keys: ["&"],
      actions: ["kill-window"],
      target: :dispatch,
      group: :sessions,
      display: "&",
      desc: "close this window (undoable — see the toast)"
    },
    %{
      keys: ["r"],
      actions: ["restore-window"],
      target: :dispatch,
      group: :sessions,
      display: "r",
      desc: "restore the window you just closed"
    },
    %{
      keys: ["y"],
      actions: ["copy-link"],
      target: :dispatch,
      group: :sessions,
      display: "y",
      desc: "copy a link to this session and window"
    },
    %{
      keys: ["d"],
      actions: ["detach"],
      target: :dispatch,
      group: :sessions,
      display: "d",
      desc: "return to the workspace shell",
      palette_ids: ["session:switch:shell"]
    },

    # --- Panes ----------------------------------------------------------------
    %{
      keys: ["%", "|"],
      actions: ["split-right"],
      target: :dispatch,
      group: :panes,
      display: "% or |",
      desc: "split side by side",
      palette_ids: ["tmux:split_right"]
    },
    %{
      keys: ["\"", "-"],
      actions: ["split-down"],
      target: :dispatch,
      group: :panes,
      display: "\" or -",
      desc: "split top and bottom",
      palette_ids: ["tmux:split_down"]
    },
    %{
      keys: ["ArrowLeft", "ArrowDown", "ArrowUp", "ArrowRight"],
      actions: ["pane-left", "pane-down", "pane-up", "pane-right"],
      target: :dispatch,
      group: :panes,
      display: "← ↓ ↑ →",
      desc: "move focus between panes"
    },
    %{
      keys: ["o"],
      actions: ["pane-next"],
      target: :dispatch,
      group: :panes,
      display: "o",
      desc: "focus the next pane",
      palette_ids: ["tmux:next_pane"]
    },
    %{
      keys: [";"],
      actions: ["last-pane"],
      target: :dispatch,
      group: :panes,
      display: ";",
      desc: "focus your last pane"
    },
    # These two dispatched and carried palette hints but had no cheatsheet row
    # until the table generated one.
    %{
      keys: ["{", "}"],
      actions: ["pane-swap-previous", "pane-swap-next"],
      target: :dispatch,
      group: :panes,
      display: "{ / }",
      desc: "swap this pane with the previous or next one",
      palette_ids: ["tmux:swap_previous", "tmux:swap_next"]
    },
    %{
      keys: ["z"],
      actions: ["zoom"],
      target: :dispatch,
      group: :panes,
      display: "z",
      desc: "zoom this pane full screen",
      palette_ids: ["tmux:zoom"]
    },
    %{
      keys: ["x"],
      actions: ["close-pane"],
      target: :dispatch,
      group: :panes,
      display: "x",
      desc: "close this pane",
      palette_ids: ["tmux:close_pane"]
    },
    %{
      keys: ["q"],
      actions: ["pane-overlay"],
      target: :client,
      group: :panes,
      display: "q",
      desc: "show pane numbers — then press 0–9 to jump"
    },

    # --- More -----------------------------------------------------------------
    %{
      keys: [":"],
      actions: ["palette"],
      target: :dispatch,
      group: :more,
      display: ":",
      desc: "open the command palette"
    },
    %{
      keys: ["?"],
      actions: ["help"],
      target: :dispatch,
      group: :more,
      display: "?",
      desc: "show this help"
    },
    %{
      keys: [],
      actions: [],
      target: :client,
      group: :more,
      display: "Esc / Ctrl + B",
      desc: "cancel (when waiting for a second key)"
    }
  ]

  @doc "Every binding entry, in cheatsheet order."
  @spec all() :: [map()]
  def all, do: @bindings

  @doc """
  `%{second_key => leader action name}` — the map the browser hook dispatches on.

  Serialized onto the `WorkspaceLeader` hook element and passed into
  `leaderSecondKeyDecision`, so the JS holds no keymap of its own.
  """
  @spec key_map() :: %{optional(String.t()) => String.t()}
  def key_map do
    for binding <- @bindings,
        {key, action} <- zip_keys(binding),
        into: %{},
        do: {key, action}
  end

  @doc "Leader action names expected to have a hidden dispatch button in the shell."
  @spec dispatch_actions() :: [String.t()]
  def dispatch_actions do
    for %{target: :dispatch} = binding <- @bindings, action <- binding.actions, do: action
  end

  @doc """
  The canonical second key for a leader action, or `nil` when unbound.

  For the visible chrome controls, which render the bare key as their
  leader-mode glyph (`data-leader-second-key`) rather than a `C-b …` string.
  """
  @spec key_for_action(String.t()) :: String.t() | nil
  def key_for_action(action) when is_binary(action) do
    Enum.find_value(@bindings, fn binding ->
      case Enum.find_index(binding.actions, &(&1 == action)) do
        nil -> nil
        idx -> positional_key(binding, idx)
      end
    end)
  end

  @doc """
  The `"C-b ,"`-style hint for a leader action name, or `nil` when unbound.

  For palette items whose id is built at runtime (`rename:window:<id>`), where
  matching on id is not possible.
  """
  @spec hint_for_action(String.t()) :: String.t() | nil
  def hint_for_action(action) when is_binary(action) do
    case key_for_action(action) do
      nil -> nil
      key -> "C-b " <> key
    end
  end

  @doc """
  The `"C-b z"`-style hint for a palette item id, or `nil` when unbound.

  Uses the key that actually maps to that item's action, so a paired entry
  (`{` / `}`) gives each item its own key rather than both showing the first.
  """
  @spec hint_for(String.t()) :: String.t() | nil
  def hint_for(item_id) when is_binary(item_id) do
    Enum.find_value(@bindings, fn binding ->
      case Enum.find_index(Map.get(binding, :palette_ids, []), &(&1 == item_id)) do
        nil -> nil
        idx -> if key = positional_key(binding, idx), do: "C-b " <> key
      end
    end)
  end

  @doc "Set `:hint` on any palette item this keymap binds, leaving others untouched."
  @spec decorate(list()) :: list()
  def decorate(items) do
    Enum.map(items, fn item ->
      case hint_for(item.id) do
        nil -> item
        hint -> %{item | hint: hint}
      end
    end)
  end

  @doc "Cheatsheet groups, each with its ordered rows (`:display` + `:desc`)."
  @spec groups() :: [%{id: atom(), label: String.t(), rows: [map()]}]
  def groups do
    Enum.map(@groups, fn group ->
      Map.put(group, :rows, Enum.filter(@bindings, &(&1.group == group.id)))
    end)
  end

  # Synonym entries (one action, many keys) always report the first key; paired
  # entries report the key at the same position as the action.
  defp positional_key(%{keys: []}, _idx), do: nil
  defp positional_key(%{keys: keys, actions: [_only]}, _idx), do: List.first(keys)
  defp positional_key(%{keys: keys}, idx), do: Enum.at(keys, idx) || List.first(keys)

  # One action → every key is a synonym; equal lengths → positional pairing.
  defp zip_keys(%{keys: [], actions: _}), do: []
  defp zip_keys(%{keys: keys, actions: [action]}), do: Enum.map(keys, &{&1, action})
  defp zip_keys(%{keys: keys, actions: actions}), do: Enum.zip(keys, actions)
end
