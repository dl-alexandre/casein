defmodule CaseinWeb.WorkspaceLive.Show.ActionAvailability do
  @moduledoc """
  One answer to "can this action run right now?", shared by every surface that
  offers it.

  The cockpit exposes the same actions through three surfaces — the command
  palette, the `C-b` leader map, and the inline chrome buttons — and each used
  to decide availability for itself: id lists in `PaletteItems`, `:if`
  conditionals on the hidden leader buttons in `WorkspaceShell`, and `disabled`
  attributes on the visible controls. Three answers to one question can
  disagree, and when they do the user gets a control that is offered but whose
  handler then denies it ("that action isn't available here").

  ## Hard vs. soft

  Two different questions were tangled together in the old id lists:

    * `available?/2` — **hard** gate. The action's handler would deny it, so no
      surface may offer it. Hiding it is a correctness requirement.
    * `relevant?/2` — **soft** gate. The action would succeed but is pointless
      in the current state (pane verbs with only one pane). It is dropped from
      the palette's default listing only, and comes back as soon as the user
      types a query — searching for something is evidence they want it.

  The split matters: pane swap is *both* (mutation-gated and pointless with one
  pane), and conflating them would either hide it from search or offer it when
  it cannot run.

  Rules are keyed by both palette item id and LiveView event, because the
  surfaces address the same action by different names (`PaletteItems` filters
  `%Item{id: "tmux:split_right"}`; the chrome renders `phx-click="split_right"`).

  The rules are pure functions of `t:t/0`, which `context/1` extracts from the
  socket once — so they are testable without building a LiveView socket.
  """

  @typedoc "Everything the availability rules are allowed to depend on."
  @type t :: %__MODULE__{
          tmux_mutations_allowed?: boolean(),
          tmux_session?: boolean(),
          raw_terminal?: boolean(),
          pane_count: non_neg_integer()
        }

  defstruct tmux_mutations_allowed?: false,
            tmux_session?: false,
            raw_terminal?: false,
            pane_count: 0

  # Structural pane/layout mutations denied by the tmux-mutation gate.
  @requires_mutations ~w(
    tmux:new_window tmux:new_window_tab tmux:consolidate_sessions
    tmux:swap_previous tmux:swap_next agents:apply_pair
  )

  # Pane verbs handled by the raw Ghostty surface; `WindowTerminalMode` keeps
  # terminals raw-everywhere, so today this is inert — it stays declared so the
  # gate does not silently vanish if a non-raw surface ever returns.
  @requires_raw_terminal ~w(
    split_right split_down pane:zoom_focused pane:close_focused pane:close_others
  )

  # Pane navigation addresses a live tmux target.
  @requires_tmux_session ~w(pane:navigate)

  # Diff inspector open always falls back to the full-area diff tab, so it is
  # never hard-denied. Listed here so the rule lives next to the other action
  # gates rather than as a second id list in the palette filter.
  @always_available ~w(diff:open_in_pane)

  # Pointless with a single pane, but not denied — soft.
  @requires_multi_pane ~w(
    tmux:next_pane tmux:previous_pane tmux:swap_previous tmux:swap_next
    tmux:close_other_panes tmux:cycle_layout tmux:equalize
  )

  @doc "Extract the availability context from a LiveView socket."
  @spec context(Phoenix.LiveView.Socket.t() | map()) :: t()
  def context(%{assigns: assigns}), do: context(assigns)

  def context(assigns) when is_map(assigns) do
    %__MODULE__{
      tmux_mutations_allowed?: assigns[:tmux_mutations_enabled?] == true,
      tmux_session?: is_binary(assigns[:tmux_session]),
      raw_terminal?: assigns[:terminal_mode] in [:raw, :raw_ghostty],
      pane_count: length(assigns[:tmux_panes] || [])
    }
  end

  @doc """
  Whether `action` may be offered at all.

  A `false` here means the handler would deny the action, so every surface must
  hide or disable it. Actions with no rule are always available.
  """
  @spec available?(String.t(), t()) :: boolean()
  def available?(action, %__MODULE__{} = ctx) do
    cond do
      action in @always_available -> true
      action in @requires_mutations -> ctx.tmux_mutations_allowed?
      action in @requires_raw_terminal -> ctx.raw_terminal?
      action in @requires_tmux_session -> ctx.tmux_session?
      true -> true
    end
  end

  @doc """
  Whether `action` is worth listing unprompted.

  Only the palette's default (empty-query) listing consults this; an action that
  is available but irrelevant must still be reachable by searching for it.
  """
  @spec relevant?(String.t(), t()) :: boolean()
  def relevant?(action, %__MODULE__{} = ctx) do
    if action in @requires_multi_pane, do: ctx.pane_count > 1, else: true
  end

  @doc """
  `available?/2` for a palette item.

  An item names its action twice — its own id (`"tmux:split_right"`) and the
  event it dispatches (`"split_right"`) — and rules may be keyed by either, so
  both have to clear.
  """
  @spec item_available?(map(), t()) :: boolean()
  def item_available?(item, %__MODULE__{} = ctx),
    do: available?(item.id, ctx) and available?(item_event(item), ctx)

  @doc "`relevant?/2` for a palette item. See `item_available?/2` on the double key."
  @spec item_relevant?(map(), t()) :: boolean()
  def item_relevant?(item, %__MODULE__{} = ctx),
    do: relevant?(item.id, ctx) and relevant?(item_event(item), ctx)

  # "" matches no rule, so an item without a dispatchable event is unrestricted.
  defp item_event(%{payload: %{event: event}}) when is_binary(event), do: event
  defp item_event(_item), do: ""

  @doc "Action ids subject to the tmux-mutation gate."
  @spec mutation_gated() :: [String.t()]
  def mutation_gated, do: @requires_mutations
end
