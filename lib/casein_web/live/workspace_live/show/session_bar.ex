defmodule CaseinWeb.WorkspaceLive.Show.SessionBar do
  @moduledoc """
  The terminal session bar (session tabs) and tmux window bar (window tabs).

  Pure presentation with a compiler-checked attr contract: both components
  consume precomputed view-models from `SessionBarVM` and emit events handled
  by the parent LiveView (`attach_terminal_session`, `terminal:*`, `tmux:*`).
  They apply `mutations_allowed?` but never decide policy themselves.

  DOM ids (`terminal-session-tabs-<ws>`, `active_sessions-<id>`,
  `tmux-window-<frag>`, `tmux-window-activity-<frag>`, ...) are a stable
  contract relied on by tests and the palette.
  """

  use CaseinWeb, :html

  import CaseinWeb.WorkspaceLive.Show.UI,
    only: [leader_key_button: 1, dom_fragment: 1, panel_state: 1]

  alias CaseinWeb.WorkspaceLive.Show.LeaderBindings
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM
  alias CaseinWeb.WorkspaceRoutes

  attr :workspace_id, :string, required: true
  attr :tabs, :list, required: true, doc: "SessionBarVM.session_tabs/1 view-models"
  attr :workspace_tabs, :list, default: [], doc: "SessionBarVM.workspace_session_tabs/2 links"
  attr :active_id, :string, default: nil, doc: "current terminal_sid"
  attr :shell_active?, :boolean, required: true
  attr :shell_label, :string, default: "workspace"
  attr :shell_detail, :string, default: ""
  attr :shell_title, :string, default: "Workspace shell"
  attr :path_base, :string, default: nil

  def session_tabs(assigns) do
    ~H"""
    <div
      id={"terminal-session-tabs-" <> @workspace_id}
      class="mb-2 flex shrink-0 items-center gap-1 overflow-x-auto border-b border-base-300/70 pb-1"
      aria-label="Terminal sessions"
    >
      <div class="flex min-w-0 flex-1 items-center gap-1">
        <a
          id={"terminal-session-shell-" <> @workspace_id}
          href={workspace_href(@workspace_id, @path_base)}
          phx-click="terminal:switch_to_shell"
          class={terminal_tab_class(@shell_active?)}
          title={@shell_title}
        >
          <span class="max-w-44 truncate font-medium">{@shell_label}</span>
          <span
            :if={@shell_detail != ""}
            class="mt-density-label max-w-44 truncate font-mono text-density-label text-primary/80"
          >
            {@shell_detail}
          </span>
        </a>
        <div id="active-sessions" class="contents">
          <%= for tab <- @tabs do %>
            <a
              id={tab.dom_id}
              href={session_href(@workspace_id, tab.id, @path_base)}
              phx-click="attach_terminal_session"
              phx-value-session-id={tab.id}
              phx-value-kind={Atom.to_string(tab.kind)}
              phx-value-tmux-session={tab.tmux_session}
              data-ctx-menu="session_tab"
              data-ctx-session-id={tab.id}
              data-ctx-kind={Atom.to_string(tab.kind)}
              data-ctx-tmux-session={tab.tmux_session}
              data-ctx-href={session_href(@workspace_id, tab.id, @path_base)}
              data-agent-reference-kind="session"
              data-agent-reference-workspace-id={@workspace_id}
              data-agent-reference-session-id={tab.id}
              data-agent-reference-tmux-session={tab.tmux_session}
              data-agent-reference-label={tab.label}
              draggable="true"
              class={terminal_tab_class(@active_id == tab.id)}
              title={tab.title}
            >
              <span class="max-w-44 truncate font-medium">{tab_anchor_label(tab)}</span>
              <span
                :if={tab_anchor_detail(tab) != ""}
                class="mt-density-label max-w-44 truncate font-mono text-density-label text-primary/80"
              >
                {tab_anchor_detail(tab)}
              </span>
            </a>
          <% end %>
        </div>
        <%= for tab <- @workspace_tabs do %>
          <%= if tab.href do %>
            <.link
              id={tab.dom_id}
              navigate={tab.href}
              class={terminal_tab_class(false)}
              title={tab.title}
            >
              <span class="max-w-44 truncate font-medium">{tab_anchor_label(tab)}</span>
              <span
                :if={tab_anchor_detail(tab) != ""}
                class="mt-density-label max-w-44 truncate font-mono text-density-label text-primary/80"
              >
                {tab_anchor_detail(tab)}
              </span>
            </.link>
          <% else %>
            <button
              id={tab.dom_id}
              type="button"
              class={terminal_tab_class(false)}
              title={tab.title}
              aria-disabled="true"
              disabled
            >
              <span class="max-w-44 truncate font-medium">{tab_anchor_label(tab)}</span>
              <span
                :if={tab_anchor_detail(tab) != ""}
                class="mt-density-label max-w-44 truncate font-mono text-density-label text-primary/80"
              >
                {tab_anchor_detail(tab)}
              </span>
            </button>
          <% end %>
        <% end %>
      </div>
      <button
        type="button"
        phx-click="terminal:refresh_sessions"
        class="shrink-0 rounded border border-base-300 px-1.5 py-0.5 text-xs text-base-content/55 transition hover:bg-base-200 hover:text-base-content"
        title="Refresh attachable sessions"
        aria-label="Refresh attachable sessions"
      >
        ↻
      </button>
    </div>
    """
  end

  attr :window, :map, required: true
  attr :picker_label?, :boolean, default: false
  attr :name_class, :string, default: "min-w-0 truncate font-medium"

  attr :show_index?, :boolean,
    default: true,
    doc:
      "false when the caller renders the index itself (e.g. tab bar copy-number sits outside the select-anchor)"

  defp window_row_name(assigns) do
    ~H"""
    <span :if={@show_index?} class="shrink-0 font-mono text-density-label text-base-content/45">
      {@window.index}
    </span>
    <%= if @picker_label? do %>
      <span data-picker-label class={@name_class}>{@window.display_name}</span>
    <% else %>
      <span class={@name_class}>{@window.display_name}</span>
    <% end %>
    """
  end

  @doc false
  attr :window, :map, required: true
  attr :copy_url, :string, default: nil

  # The window index, rendered as its own element so the tab bar can place it
  # OUTSIDE the window-select anchor: when it carries a session+window deep
  # link it is a copy-only affordance (a click copies and, sitting outside the
  # anchor, never also selects the window). Falls back to a plain index label.
  defp window_index_badge(assigns) do
    ~H"""
    <span
      :if={is_binary(@copy_url) and @copy_url != ""}
      data-copy-session-link={@copy_url}
      data-copy-link-kind="window"
      role="button"
      tabindex="-1"
      class="shrink-0 cursor-copy rounded px-density-label font-mono text-density-label text-base-content/45 underline decoration-dotted decoration-base-content/25 underline-offset-2 transition-colors duration-motion-state ease-motion-state hover:bg-base-300/60 hover:text-base-content hover:decoration-base-content/60"
      title="Copy link to this session + window"
      aria-label="Copy link to this session and window"
    >{@window.index}</span>
    <span
      :if={!(is_binary(@copy_url) and @copy_url != "")}
      class="shrink-0 font-mono text-density-label text-base-content/45"
    >{@window.index}</span>
    """
  end

  attr :window, :map, required: true
  attr :preview_id, :string, default: nil
  attr :activity_id, :string, default: nil
  attr :preview_aria_hidden?, :boolean, default: false

  defp window_row_indicators(assigns) do
    ~H"""
    <span
      :if={@window.preview?}
      id={@preview_id}
      data-preview-window={@preview_id && "true"}
      data-preview-count={@preview_id && @window.preview_count}
      class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-status-live/15 text-status-live-fg ring-1 ring-status-live/30"
      title={window_preview_tooltip(@window.preview_count, @preview_aria_hidden?)}
      aria-label={
        if(@preview_aria_hidden?, do: nil, else: window_preview_tooltip(@window.preview_count, false))
      }
      aria-hidden={@preview_aria_hidden? || nil}
    >
      <.icon name="hero-globe-alt" class="size-3" />
    </span>
    <span
      :if={window_agent_chip_text(@window)}
      data-agent-state={@window.agent_state}
      class={[
        "shrink-0 rounded-full px-1.5 text-[9px] font-semibold",
        window_agent_chip_class(@window)
      ]}
      title={@window.activity_label}
      aria-label={@window.activity_label}
    >
      {window_agent_chip_text(@window)}
    </span>
    <span
      id={@activity_id}
      data-activity-state={@activity_id && @window.activity_state}
      data-agent-state={@window.agent_state}
      class={["size-1.5 shrink-0 rounded-full", @window.activity_class]}
      title={@window.activity_label}
      aria-label={@window.activity_label}
    ></span>
    """
  end

  defp window_agent_chip_text(%{agent_state_chip: text}) when is_binary(text) and text != "",
    do: text

  defp window_agent_chip_text(_), do: nil

  defp window_agent_chip_class(%{agent_state_chip_class: class})
       when is_binary(class) and class != "",
       do: class

  defp window_agent_chip_class(_), do: "bg-base-content/10 text-base-content/70"

  attr :window, :map, required: true
  attr :id_suffix, :string, default: ""
  attr :form_class, :string, default: "ml-1 flex items-center gap-1"
  attr :input_class, :string, required: true
  attr :show_cancel?, :boolean, default: true

  defp window_inline_rename_form(assigns) do
    ~H"""
    <.form
      for={to_form(%{"id" => @window.id, "name" => @window.name}, as: :window)}
      id={"tmux-rename-form" <> @id_suffix <> "-" <> @window.dom_frag}
      phx-submit="tmux:rename_window"
      class={@form_class}
    >
      <input type="hidden" name="window[id]" value={@window.id} />
      <input
        type="text"
        id={"tmux-rename-input" <> @id_suffix <> "-" <> @window.dom_frag}
        name="window[name]"
        value={@window.name}
        phx-hook="RenameInput"
        phx-keydown="tmux:rename_cancel"
        phx-key="Escape"
        autocomplete="off"
        class={@input_class}
      />
      <button
        type="submit"
        class={
          if(@show_cancel?,
            do: "rounded p-1 text-primary hover:bg-primary/10",
            else: "rounded p-0.5 text-primary"
          )
        }
        aria-label="Save window name"
        title={if(@show_cancel?, do: "Save window name", else: nil)}
      >
        <.icon name="hero-check" class="size-3.5" />
      </button>
      <button
        :if={@show_cancel?}
        type="button"
        phx-click="tmux:rename_cancel"
        class="rounded p-1 text-base-content/45 hover:bg-base-200 hover:text-base-content"
        title="Cancel rename"
        aria-label="Cancel rename"
      >
        <.icon name="hero-x-mark" class="size-3.5" />
      </button>
    </.form>
    """
  end

  defp window_preview_tooltip(count, sidebar?) do
    if sidebar? do
      "Preview pane open (#{count})"
    else
      "Preview pane open in this window (#{count})"
    end
  end

  attr :workspace_id, :string, required: true
  attr :windows, :list, required: true, doc: "SessionBarVM.window_tabs/1 view-models"
  attr :topology_version, :integer, default: 0
  attr :mutations_allowed?, :boolean, required: true
  attr :rename_window_id, :string, default: nil
  attr :path_base, :string, default: nil

  attr :terminal_mode, :atom,
    default: nil,
    doc: "active terminal mode — enables pane split/zoom controls in the selected tab"

  attr :window_zoomed?, :boolean,
    default: false,
    doc: "focused pane zoom state for the zoom toggle"

  attr :terminal_sid, :string,
    default: nil,
    doc: "active session id — lets each tab's index copy a session+window deep link"

  attr :class, :any,
    default: "mb-2 shrink-0 border-b border-base-300 pb-1",
    doc: "layout-context classes — override to embed the strip inline (e.g. in the header)"

  def window_tabs(assigns) do
    ~H"""
    <div
      :if={@windows != []}
      id={"tmux-window-tabs-" <> @workspace_id}
      phx-hook="WindowTabStrip"
      data-version={@topology_version}
      data-mutations-allowed={to_string(@mutations_allowed?)}
      class={["flex min-w-0 items-center gap-1", @class]}
    >
      <div
        data-tab-scroller
        class="tab-strip-scroller flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
      >
        <%= for {window, tab_idx} <- Enum.with_index(@windows) do %>
          <div
            id={"tmux-window-" <> window.dom_frag}
            data-ctx-menu="window_tab"
            data-ctx-window-id={window.id}
            data-ctx-href={window_href(@workspace_id, window.id, path_base: @path_base)}
            data-active-window={window.active? || nil}
            data-window-leader-key={window_leader_key(@windows, window, tab_idx)}
            data-window-index={window.index}
            data-window-name={window.display_name}
            data-window-activity={window.activity_state}
            data-window-attention={window.attention}
            data-agent-reference-kind="window"
            data-agent-reference-workspace-id={@workspace_id}
            data-agent-reference-session-id={@terminal_sid}
            data-agent-reference-window-id={window.id}
            data-agent-reference-window-index={window.index}
            data-agent-reference-label={window.display_name}
            class={[
              "group relative flex min-w-24 shrink-0 items-center gap-1 rounded-t border border-b-0 px-2 py-1 text-xs transition-colors duration-motion-state ease-motion-state",
              if(window.active?,
                do: "max-w-80 border-primary bg-base-100 text-base-content shadow-sm",
                else:
                  "max-w-64 border-base-300 bg-base-200/70 text-base-content/65 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <.window_index_badge
              window={window}
              copy_url={share_url(@workspace_id, @terminal_sid, window.id, path_base: @path_base)}
            />
            <a
              href={window_href(@workspace_id, window.id, path_base: @path_base)}
              data-window-tab-select
              phx-click="tmux:select_window"
              phx-value-window-id={window.id}
              data-tmux-window-index={window.index}
              class="flex min-w-0 flex-1 items-center gap-1"
              title={"Select tmux window " <> window.full_title}
            >
              <.window_row_name window={window} show_index?={false} />
              <.window_row_indicators
                window={window}
                preview_id={"tmux-window-preview-" <> window.dom_frag}
                activity_id={"tmux-window-activity-" <> window.dom_frag}
              />
            </a>
            <%!-- Window controls live in the tab. On the selected tab they're
                  pinned; on the rest they collapse to zero width and reveal on
                  hover/focus so unselected tabs stay compact. Splits + zoom act
                  on the active window's focused pane, so they render only in the
                  selected tab. Leader dispatch stays on the hidden C-b targets. --%>
            <%= if @mutations_allowed? do %>
              <div class={[
                "flex shrink-0 items-center gap-0.5",
                if(window.active?, do: nil, else: "hidden group-hover:flex group-focus-within:flex")
              ]}>
                <%= if @rename_window_id == window.id do %>
                  <.window_inline_rename_form
                    window={window}
                    input_class="h-6 w-28 rounded border border-base-300 bg-base-100 px-2 py-0 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
                  />
                <% else %>
                  <button
                    type="button"
                    phx-click="tmux:rename_start"
                    phx-value-window-id={window.id}
                    class="rounded p-1 text-base-content/35 transition hover:bg-base-300 hover:text-base-content"
                    title="Rename tmux window"
                    aria-label="Rename tmux window"
                  >
                    <.icon name="hero-pencil-square" class="size-3.5" />
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click="tmux:kill_window"
                  phx-value-window-id={window.id}
                  class="rounded p-1 text-base-content/35 transition hover:bg-error/10 hover:text-error"
                  title="Close tmux window"
                  aria-label="Close tmux window"
                  disabled={length(@windows) <= 1}
                >
                  <.icon name="hero-x-mark" class="size-3.5" />
                </button>

                <%= if window.active? and @terminal_mode in [:raw, :raw_ghostty] do %>
                  <span class="mx-0.5 h-4 w-px shrink-0 bg-base-300"></span>
                  <.leader_key_button
                    key={LeaderBindings.key_for_action("split-right")}
                    phx_click="split_right"
                    title={"Split right · Ctrl + B " <> LeaderBindings.key_for_action("split-right")}
                    aria_label="Split pane right"
                  >
                    <.split_icon direction={:right} class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key={LeaderBindings.key_for_action("split-down")}
                    phx_click="split_down"
                    title={"Split down · Ctrl + B " <> LeaderBindings.key_for_action("split-down")}
                    aria_label="Split pane down"
                  >
                    <.split_icon direction={:down} class="size-3.5" />
                  </.leader_key_button>
                  <.leader_key_button
                    key={LeaderBindings.key_for_action("zoom")}
                    phx_click="pane:zoom_focused"
                    title={
                      (if @window_zoomed?, do: "Unzoom pane", else: "Zoom pane") <>
                        " · Ctrl + B " <> LeaderBindings.key_for_action("zoom")
                    }
                    aria_label={if @window_zoomed?, do: "Unzoom pane", else: "Zoom pane"}
                  >
                    <.icon
                      name={
                        if @window_zoomed?,
                          do: "hero-arrows-pointing-in",
                          else: "hero-arrows-pointing-out"
                      }
                      class="size-3.5"
                    />
                  </.leader_key_button>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
      <%= if @mutations_allowed? do %>
        <button
          type="button"
          phx-click="tmux:new_window"
          class="leader-key-control relative shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
          data-leader-second-key={LeaderBindings.key_for_action("new-window")}
          title={"New window · Ctrl + B " <> LeaderBindings.key_for_action("new-window")}
          aria-label="New tmux window"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      <% end %>
    </div>
    """
  end

  # Leader-armed badge for a window tab:
  #   * prev of active → "p" (C-b p)
  #   * next of active → "n" (C-b n)
  #   * otherwise index 0–9 → that digit (C-b 0–9)
  # Neighbours win over digits so sequential n/p browsing stays obvious.
  defp window_leader_key(windows, window, tab_idx) when is_list(windows) do
    active_idx = Enum.find_index(windows, & &1.active?)

    cond do
      is_integer(active_idx) and tab_idx == active_idx - 1 ->
        "p"

      is_integer(active_idx) and tab_idx == active_idx + 1 ->
        "n"

      is_integer(window.index) and window.index >= 0 and window.index <= 9 ->
        Integer.to_string(window.index)

      true ->
        nil
    end
  end

  defp window_leader_key(_windows, _window, _tab_idx), do: nil

  attr :workspace_id, :string, required: true
  attr :tree, :list, required: true, doc: "SessionBarVM.workspace_session_tree/4 nodes"
  attr :needs_you, :list, default: [], doc: "SessionBarVM.needs_you_strip/3 rows"
  attr :active_id, :string, default: nil
  attr :default_sid, :string, default: nil
  attr :preview_panes, :map, default: %{}
  attr :path_base, :string, default: nil
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_session_id, :string, default: nil
  attr :session_tabs, :list, default: [], doc: "for quiet/attention badge aggregate"
  attr :chrome_visible?, :boolean, default: true, doc: "focus-mode state for the header toggle"

  attr :sort_mode, :atom, default: :recency

  attr :class, :any,
    default: nil,
    doc: "layout classes — desktop-only summoned SESSIONS rail"

  def sessions_sidebar(assigns) do
    ~H"""
    <%!-- Deliberately not gated on `@tree != []`: the rail is the primary
    session-switching surface, so summoning it must paint chrome immediately and
    fill rows in as they arrive, never leave an empty column. --%>
    <nav
      id={"sessions-sidebar-" <> @workspace_id}
      data-sessions-picker-sidebar="true"
      data-shortcut="Ctrl + B, then S"
      data-leader-second-key="S"
      phx-hook="SessionsPickerSidebar"
      aria-label="Workspaces and sessions"
      class={
        [
          # Fixed rail width (not free-expand): two open columns stay side-by-side
          # without labels painting into each other. Opaque bg + overflow clip.
          "sessions-picker-sidebar leader-key-control relative z-[2] flex w-64 max-w-[40vw] shrink-0 flex-col overflow-hidden border-r border-base-300/70 bg-base-100",
          @class
        ]
      }
    >
      <div
        data-ctx-menu="sessions_rail"
        class="flex shrink-0 items-center justify-between gap-1.5 border-b border-base-300/70 px-3 py-1.5"
      >
        <span class="flex min-w-0 items-center gap-1.5">
          <span class="text-density-body font-semibold tracking-wide text-base-content/70">
            Sessions
          </span>
          <% liveness = SessionBarVM.tree_liveness_summary(@tree) %>
          <span
            :if={liveness.total > 0}
            class="shrink-0 rounded-full bg-base-200 px-1.5 py-density-label font-mono text-density-label leading-none tabular-nums text-base-content/70"
            title={"#{liveness.live} of #{liveness.total} workspaces have a live session"}
            aria-label={"#{liveness.live} of #{liveness.total} workspaces live"}
          >
            {liveness.live}/{liveness.total} live
          </span>
          <span
            :if={quiet_window_count(@session_tabs) > 0}
            id={"session-quiet-badge-" <> @workspace_id}
            data-attention={quiet_badge_attention(@session_tabs)}
            class={quiet_badge_class(quiet_badge_attention(@session_tabs))}
            title={
              quiet_badge_label(
                quiet_window_count(@session_tabs),
                unseen_quiet_window_count(@session_tabs)
              )
            }
            aria-label={
              quiet_badge_label(
                quiet_window_count(@session_tabs),
                unseen_quiet_window_count(@session_tabs)
              )
            }
          ></span>
        </span>
        <%!-- Sort keeps its word: the label *is* the current mode, and an icon
        alone cannot say "Recent" vs "Name". Focus mode is a plain toggle, so it
        reduces to an icon and drops the ambiguous "Focus"/"Chrome" wording. --%>
        <span class="flex shrink-0 items-center gap-1">
          <button
            type="button"
            phx-click="sidebar:cycle_sessions_sort"
            class="flex items-center gap-1 rounded border border-base-300/70 px-1.5 py-density-label text-density-label text-base-content/70 hover:bg-base-200 hover:text-base-content"
            title={"Sorted by " <> SessionBarVM.sort_mode_label(@sort_mode) <> " — click to cycle"}
            aria-label={
              "Sorted by " <> SessionBarVM.sort_mode_label(@sort_mode) <> ", click to cycle"
            }
          >
            <.icon name="hero-bars-arrow-down" class="size-3" />
            {SessionBarVM.sort_mode_label(@sort_mode)}
          </button>
          <button
            type="button"
            id={"sessions-focus-mode-" <> @workspace_id}
            phx-click="terminal:toggle_chrome"
            data-shortcut="Ctrl/Cmd + Shift + F"
            class="flex items-center rounded p-1 text-base-content/60 hover:bg-base-200 hover:text-base-content"
            title={
              if(@chrome_visible?,
                do: "Focus mode — hide header. Shortcut: Ctrl/Cmd + Shift + F",
                else: "Show header. Shortcut: Ctrl/Cmd + Shift + F"
              )
            }
            aria-label={if(@chrome_visible?, do: "Enter focus mode", else: "Exit focus mode")}
            aria-pressed={to_string(not @chrome_visible?)}
          >
            <.icon
              name={
                if(@chrome_visible?, do: "hero-arrows-pointing-in", else: "hero-arrows-pointing-out")
              }
              class="size-3.5"
            />
          </button>
        </span>
      </div>
      <div class="flex shrink-0 items-center gap-1.5 border-b border-base-300/70 px-2 py-1">
        <.icon name="hero-funnel" class="size-3 shrink-0 text-base-content/50" />
        <span
          data-picker-filter
          data-picker-filter-placeholder="Type to filter"
          data-picker-filter-empty
          class="min-w-0 truncate font-mono text-density-body text-base-content/75"
        >
          Type to filter
        </span>
      </div>
      <.sessions_needs_you_strip
        rows={@needs_you}
        workspace_id={@workspace_id}
        active_id={@active_id}
        path_base={@path_base}
      />
      <div class="min-h-0 min-w-0 w-full flex-1 overflow-y-auto overflow-x-hidden px-1 py-1.5">
        <% {ws_nodes, browse_nodes} =
          Enum.split_with(@tree, &(Map.get(&1, :kind) not in [:browse_root, :browse_dir])) %>
        <% grouped = Enum.group_by(ws_nodes, &Map.get(&1, :group, :other)) %>
        <% this_nodes = Map.get(grouped, :this, []) %>
        <% mine_nodes = Map.get(grouped, :mine, []) %>
        <% other_nodes = Map.get(grouped, :other, []) %>
        <% multi_section? = Enum.count([this_nodes, mine_nodes, other_nodes], &(&1 != [])) > 1 %>
        <.sessions_sidebar_group
          nodes={this_nodes}
          label="This workspace"
          show_label?={multi_section?}
          first?={true}
          workspace_id={@workspace_id}
          active_id={@active_id}
          default_sid={@default_sid}
          preview_panes={@preview_panes}
          path_base={@path_base}
          mutations_allowed?={@mutations_allowed?}
          rename_session_id={@rename_session_id}
        />
        <.sessions_sidebar_group
          nodes={mine_nodes}
          label="My workspaces"
          show_label?={multi_section?}
          first?={this_nodes == []}
          workspace_id={@workspace_id}
          active_id={@active_id}
          default_sid={@default_sid}
          preview_panes={@preview_panes}
          path_base={@path_base}
          mutations_allowed?={@mutations_allowed?}
          rename_session_id={@rename_session_id}
        />
        <.sessions_sidebar_group
          nodes={other_nodes}
          label="Other workspaces"
          show_label?={multi_section?}
          first?={this_nodes == [] and mine_nodes == []}
          workspace_id={@workspace_id}
          active_id={@active_id}
          default_sid={@default_sid}
          preview_panes={@preview_panes}
          path_base={@path_base}
          mutations_allowed?={@mutations_allowed?}
          rename_session_id={@rename_session_id}
        />
        <.sessions_sidebar_browse_node :for={node <- browse_nodes} node={node} depth={0} />
        <%!-- Reached before the first summary build lands, and whenever a
        filter matches nothing. Skeleton rows keep the rail from reading as
        broken during the git-backed workspace scan. --%>
        <div :if={@tree == []} class="flex flex-col gap-1 px-1 pt-1" aria-hidden="true">
          <div
            :for={width <- ["w-3/4", "w-1/2", "w-2/3"]}
            class={["h-4 animate-pulse rounded bg-base-200", width]}
          >
          </div>
        </div>
        <p :if={@tree == []} class="px-2 pt-2 text-density-body text-base-content/60">
          Finding your sessions…
        </p>
      </div>
      <div class="flex shrink-0 items-center justify-between gap-1 border-t border-base-300/70 px-2 py-1.5">
        <span class="min-w-0 truncate font-mono text-density-label text-base-content/60">
          ↑↓ move · o open · l link
        </span>
        <button
          type="button"
          phx-click="terminal:refresh_sessions"
          class="flex shrink-0 items-center rounded p-1 text-base-content/60 hover:bg-base-200 hover:text-base-content"
          title="Refresh workspaces and sessions"
          aria-label="Refresh workspaces and sessions"
        >
          <.icon name="hero-arrow-path" class="size-3.5" />
        </button>
      </div>
    </nav>
    """
  end

  attr :nodes, :list, required: true
  attr :label, :string, required: true
  attr :show_label?, :boolean, default: true
  attr :first?, :boolean, default: false
  attr :workspace_id, :string, required: true
  attr :active_id, :string, default: nil
  attr :default_sid, :string, default: nil
  attr :preview_panes, :map, default: %{}
  attr :path_base, :string, default: nil
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_session_id, :string, default: nil

  # One ownership section of the SESSIONS rail ("This workspace" / "My
  # workspaces" / "Other workspaces"), subdivided by attention. Rendering order
  # is the arrow-key order, so the viewer's own rows are always reachable first.
  defp sessions_sidebar_group(assigns) do
    ~H"""
    <div :if={@nodes != []} class={["flex flex-col gap-0.5", not @first? && "mt-1.5"]}>
      <.sessions_sidebar_section_header :if={@show_label?} label={@label} />
      <div
        :for={{section, nodes} <- SessionBarVM.node_attention_groups(@nodes)}
        data-picker-group={section}
        class="flex flex-col gap-0.5"
      >
        <.sessions_sidebar_section_header
          label={attention_section_label(section)}
          count={length(nodes)}
          attention?={section == :needs_you}
        />
        <.sessions_sidebar_node
          :for={node <- nodes}
          node={node}
          workspace_id={@workspace_id}
          active_id={@active_id}
          default_sid={@default_sid}
          preview_panes={@preview_panes}
          path_base={@path_base}
          mutations_allowed?={@mutations_allowed?}
          rename_session_id={@rename_session_id}
        />
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :workspace_id, :string, required: true
  attr :active_id, :string, default: nil
  attr :path_base, :string, default: nil

  # Pinned cross-workspace triage queue: every session that needs you, most
  # urgent first, one click from being unblocked. Hidden entirely when nothing
  # needs attention so the rail stays calm at rest.
  #
  # #910 row order: human title · workspace+branch · chip + 1-line message.
  # Chip labels from SessionBarVM.attention_chip_label/1 only — idle ≠ stalled.
  defp sessions_needs_you_strip(assigns) do
    ~H"""
    <div
      :if={@rows != []}
      id={"sessions-needs-you-" <> @workspace_id}
      data-needs-you-strip
      data-needs-you-sessions={length(@rows)}
      class="shrink-0 border-b border-status-danger/20 bg-status-danger/[0.04] px-1 py-1"
    >
      <.sessions_sidebar_section_header
        label="Needs you"
        count={length(@rows)}
        attention?={true}
      />
      <div class="flex flex-col gap-0.5">
        <.sessions_needs_you_row
          :for={row <- @rows}
          row={row}
          current_workspace_id={@workspace_id}
          active_id={@active_id}
          path_base={@path_base}
        />
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :current_workspace_id, :string, required: true
  attr :active_id, :string, default: nil
  attr :path_base, :string, default: nil

  defp sessions_needs_you_row(assigns) do
    assigns = assign(assigns, :badge, needs_you_row_badge(assigns.row))

    ~H"""
    <%= if @row.current? do %>
      <a
        id={"needs-you-row-" <> dom_fragment(@row.id)}
        href={needs_you_row_href(@row, @path_base)}
        data-picker-item
        data-picker-label={@row.label}
        data-picker-search={@row.search_text}
        data-needs-you-reason={@row.reason}
        data-needs-you-window={@row.window_id}
        phx-click="attach_terminal_session"
        phx-value-session-id={@row.session_id}
        phx-value-kind={to_string(@row.kind)}
        phx-value-tmux-session={@row.tmux_session}
        phx-value-window-id={@row.window_id}
        class={[
          sidebar_row_class(@active_id == @row.session_id),
          "flex-col items-stretch gap-0.5 py-1.5"
        ]}
        title={needs_you_row_title(@row)}
      >
        <.needs_you_row_body row={@row} badge={@badge} show_workspace?={false} />
      </a>
    <% else %>
      <.link
        id={"needs-you-row-" <> dom_fragment(@row.id)}
        navigate={needs_you_row_href(@row, @path_base)}
        data-picker-item
        data-picker-label={@row.label}
        data-picker-search={@row.search_text}
        data-needs-you-reason={@row.reason}
        data-needs-you-window={@row.window_id}
        class={[sidebar_row_class(false), "flex-col items-stretch gap-0.5 py-1.5"]}
        title={needs_you_row_title(@row)}
      >
        <.needs_you_row_body row={@row} badge={@badge} show_workspace?={true} />
      </.link>
    <% end %>
    """
  end

  attr :row, :map, required: true
  attr :badge, :map, required: true
  attr :show_workspace?, :boolean, default: false

  # Line 1: human title. Line 2: workspace + branch. Line 3: chip + message.
  defp needs_you_row_body(assigns) do
    ~H"""
    <span class="flex min-w-0 items-center gap-1.5 overflow-hidden">
      <span
        class={["size-1.5 shrink-0 rounded-full", @badge.dot]}
        aria-hidden="true"
      />
      <span data-picker-label class="truncate font-medium">{@row.label}</span>
    </span>
    <span
      :if={needs_you_meta_line(@row, @show_workspace?) != ""}
      data-picker-label
      class="min-w-0 truncate pl-3 font-mono text-density-label text-base-content/50"
    >
      {needs_you_meta_line(@row, @show_workspace?)}
    </span>
    <span class="flex min-w-0 items-center gap-1.5 overflow-hidden pl-3">
      <span class={[
        "shrink-0 rounded-full px-1.5 text-density-badge font-semibold",
        @badge.class
      ]}>
        {@badge.text}
      </span>
      <span
        :if={is_binary(@row.message) and @row.message != ""}
        data-picker-label
        class="min-w-0 truncate text-density-label text-base-content/60"
      >
        {@row.message}
      </span>
    </span>
    """
  end

  defp needs_you_meta_line(row, show_workspace?) do
    parts =
      []
      |> then(fn acc ->
        if show_workspace? and is_binary(row.workspace_label) and row.workspace_label != "",
          do: [row.workspace_label | acc],
          else: acc
      end)
      |> then(fn acc ->
        branch = Map.get(row, :branch)

        if is_binary(branch) and branch != "" and not SessionBarVM.default_branch?(branch),
          do: [SessionBarVM.branch_short(branch) | acc],
          else: acc
      end)
      |> Enum.reverse()

    Enum.join(parts, " · ")
  end

  defp needs_you_row_href(%{href: href}, _path_base) when is_binary(href) and href != "", do: href

  defp needs_you_row_href(row, path_base) do
    base =
      if row.current? do
        session_href(row.workspace_id, row.session_id, path_base)
      else
        cross_workspace_home_path(row.workspace_id)
      end

    case Map.get(row, :window_id) do
      id when is_binary(id) and id != "" ->
        sep = if String.contains?(base, "?"), do: "&", else: "?"
        base <> sep <> URI.encode_query([{"window", id}])

      _ ->
        base
    end
  end

  # Chip catalogue is SessionBarVM.attention_chip_label/1 only (#910).
  # Stalled ≡ running_but_not_progressing — never render as idle/Quiet update.
  defp needs_you_row_badge(row) do
    reason = Map.get(row, :reason)
    count = Map.get(row, :agent_blocked_count, 0)
    base = SessionBarVM.attention_chip_label(reason)
    text = if is_integer(count) and count > 1, do: "#{base} ×#{count}", else: base

    case reason do
      r when r in [:blocked, :awaiting_input] ->
        %{dot: "bg-status-danger", class: "bg-status-danger/15 text-status-danger-fg", text: text}

      r when r in [:errored, :error] ->
        %{dot: "bg-status-danger", class: "bg-status-danger/15 text-status-danger-fg", text: text}

      :stalled ->
        %{
          dot: "bg-status-warning",
          class: "bg-status-warning/15 text-status-warning-fg",
          text: text
        }

      :completed ->
        %{dot: "bg-status-live", class: "bg-status-live/15 text-status-live-fg", text: text}

      :idle ->
        %{dot: "bg-status-idle", class: "bg-status-idle/15 text-status-idle-fg", text: text}

      _ ->
        %{dot: "bg-status-idle", class: "bg-status-idle/15 text-status-idle-fg", text: text}
    end
  end

  defp needs_you_row_title(row) do
    chip = SessionBarVM.attention_chip_label(row.reason)

    base =
      case row.reason do
        :blocked -> "Needs input"
        :awaiting_input -> "Needs input"
        r when r in [:errored, :error] -> "Error"
        :completed -> "Finished — review result"
        # Stalled is NOT idle: process active, axes not progressing (AgentProgress).
        :stalled -> "Stalled — running but not progressing"
        :idle -> "Quiet update"
        _ -> chip
      end

    scope = if(row.current?, do: base, else: base <> " · " <> row.workspace_label)

    case row.message do
      message when is_binary(message) and message != "" -> scope <> " — " <> message
      _ -> scope
    end
  end

  attr :label, :string, required: true
  attr :count, :integer, default: nil
  attr :attention?, :boolean, default: false

  defp sessions_sidebar_section_header(assigns) do
    ~H"""
    <p class={[
      "flex items-center justify-between px-2 pb-density-label pt-1 text-density-label font-semibold uppercase tracking-wide",
      @attention? && "text-status-danger-fg",
      !@attention? && "text-base-content/60"
    ]}>
      <span>{@label}</span>
      <span :if={is_integer(@count)} class="font-mono opacity-70">{@count}</span>
    </p>
    """
  end

  defp attention_section_label(:needs_you), do: "Needs you"
  defp attention_section_label(:working), do: "Working"
  defp attention_section_label(:recent), do: "Recent"

  attr :node, :map, required: true
  attr :workspace_id, :string, required: true
  attr :active_id, :string, default: nil
  attr :default_sid, :string, default: nil
  attr :preview_panes, :map, default: %{}
  attr :path_base, :string, default: nil
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_session_id, :string, default: nil

  # One workspace-tier row in the sessions sidebar: a flat single-session row, an
  # expandable workspace with its session children, or a collapsed workspace
  # summary. Non-live (stale worktree) rows are dimmed so live work stands out.
  defp sessions_sidebar_node(assigns) do
    ~H"""
    <%= cond do %>
      <% @node.flat_session? -> %>
        <.sessions_sidebar_session_row
          session={@node.session}
          workspace_id={@node.workspace_id}
          current_workspace_id={@workspace_id}
          active_id={@active_id}
          default_sid={@default_sid}
          preview_panes={@preview_panes}
          path_base={@path_base}
          parent_dom_id={nil}
          mutations_allowed?={@mutations_allowed?}
          rename_session_id={@rename_session_id}
        />
      <% is_list(@node.sessions) -> %>
        <div
          data-picker-tree-branch
          data-picker-branch-id={@node.dom_id}
          class="flex flex-col gap-0.5"
        >
          <.sessions_sidebar_workspace_header
            node={@node}
            current_workspace_id={@workspace_id}
            default_sid={@default_sid}
            path_base={@path_base}
            expandable?={true}
          />
          <div
            id={"sidebar-ws-sessions-" <> @node.workspace_id}
            data-picker-branch-children
            data-picker-collapsed={(!@node.expanded? && "") || nil}
            class={["space-y-0.5 pl-3", !@node.expanded? && "hidden"]}
          >
            <%= for {section, sessions} <- SessionBarVM.session_attention_groups(@node.sessions) do %>
              <div data-picker-group={section} class="space-y-0.5">
                <.sessions_sidebar_section_header
                  label={attention_section_label(section)}
                  count={length(sessions)}
                  attention?={section == :needs_you}
                />
                <.sessions_sidebar_session_row
                  :for={session <- sessions}
                  session={session}
                  workspace_id={Map.get(session, :workspace_id, @node.workspace_id)}
                  current_workspace_id={@workspace_id}
                  active_id={@active_id}
                  default_sid={@default_sid}
                  preview_panes={@preview_panes}
                  path_base={@path_base}
                  parent_dom_id={@node.dom_id}
                  mutations_allowed?={@mutations_allowed?}
                  rename_session_id={@rename_session_id}
                />
              </div>
            <% end %>
            <p
              :if={@node.sessions == [] and @node.loading?}
              class={[
                "flex items-center gap-1.5 px-2 py-1 font-mono text-density-label italic text-base-content/40",
                "async-wait"
              ]}
              role="status"
              aria-live="polite"
            >
              <.icon name="hero-arrow-path" class="size-3 animate-spin" /> Loading sessions…
            </p>
            <.panel_state
              :if={@node.sessions == [] and not @node.loading? and is_binary(@node.sessions_error)}
              id={@node.dom_id <> "-sessions-error"}
              kind={:error}
              message={@node.sessions_error}
              class="mx-2 my-1 px-2 py-2"
            />
            <.panel_state
              :if={@node.sessions == [] and not @node.loading? and is_nil(@node.sessions_error)}
              id={@node.dom_id <> "-sessions-empty"}
              kind={:empty}
              message="No live sessions"
              class="mx-2 my-1 border-0 bg-transparent px-2 py-1 italic"
            />
          </div>
        </div>
      <% @node.nav_href -> %>
        <.link
          navigate={@node.nav_href}
          data-picker-item
          data-picker-section="workspaces"
          data-picker-sessions-id={@node.dom_id}
          class={[
            sidebar_row_class(false),
            "flex-row items-center gap-2",
            not @node.live? && "opacity-60"
          ]}
          title={@node.title}
          aria-label={"Open " <> @node.label}
        >
          <span class="flex min-w-0 flex-1 flex-col items-start gap-0.5 overflow-hidden text-left">
            <span class="flex max-w-full items-center gap-1.5 overflow-hidden">
              <span data-picker-label class="truncate font-medium">{@node.label}</span>
              <span
                :if={not @node.live?}
                class="size-1.5 shrink-0 rounded-full bg-base-content/25"
                title="No live tmux sessions"
              />
            </span>
            <span
              :if={@node.detail != ""}
              class="max-w-full truncate font-mono text-density-label text-base-content/50"
            >
              {@node.detail}
            </span>
          </span>
          <span
            :if={@node.session_count > 0}
            class="flex shrink-0 items-center gap-density-label font-mono text-density-label text-base-content/45"
          >
            {@node.session_count}
            <.icon name="hero-arrow-right" class="size-3" />
          </span>
        </.link>
      <% true -> %>
        <div
          data-picker-tree-branch
          data-picker-branch-id={@node.dom_id}
          class="flex flex-col gap-0.5"
        >
          <.sessions_sidebar_workspace_header
            node={@node}
            current_workspace_id={@workspace_id}
            default_sid={@default_sid}
            path_base={@path_base}
            expandable?={@node.session_count > 0}
          />
        </div>
    <% end %>
    """
  end

  attr :node, :map, required: true
  attr :current_workspace_id, :string, required: true
  attr :default_sid, :string, default: nil
  attr :path_base, :string, default: nil
  attr :expandable?, :boolean, default: false

  # Workspace-tier header row. Its primary action OPENS the workspace's home
  # (landing) session — attach in place for the current workspace, navigate for
  # another — so Enter / a plain click lands you in a shell instead of merely
  # toggling the child list. Expansion moves to the dedicated chevron button
  # (and to ArrowLeft/ArrowRight in the picker hook). The row keeps
  # phx-value-workspace-id + data-picker-section="workspaces" so the keyboard
  # collapse/expand hooks still resolve which workspace to toggle.
  defp sessions_sidebar_workspace_header(assigns) do
    home = workspace_home_session(assigns.node, assigns.default_sid)

    assigns =
      assigns
      |> assign(:home, home)
      |> assign(:current?, assigns.node.workspace_id == assigns.current_workspace_id)
      |> assign(:openable?, Map.get(assigns.node, :openable?, true))

    ~H"""
    <%= if is_map(@home) do %>
      <div class="flex items-stretch gap-0.5">
        <%= if @current? do %>
          <a
            href={session_href(@node.workspace_id, @home.id, @path_base)}
            data-picker-item
            data-picker-section="workspaces"
            data-picker-sessions-id={@node.dom_id}
            phx-value-workspace-id={@node.workspace_id}
            phx-click="attach_terminal_session"
            phx-value-session-id={@home.id}
            phx-value-kind={to_string(@home.kind)}
            phx-value-tmux-session={@home.tmux_session}
            class={[
              sidebar_row_class(@node.current?),
              "min-w-0 flex-1 flex-row items-center gap-2",
              not @node.live? && "opacity-60"
            ]}
            title={workspace_home_title(@node, @home)}
          >
            <.sessions_sidebar_workspace_labels node={@node} />
          </a>
        <% else %>
          <.link
            navigate={cross_workspace_session_path(@node.workspace_id, @home)}
            data-picker-item
            data-picker-section="workspaces"
            data-picker-sessions-id={@node.dom_id}
            phx-value-workspace-id={@node.workspace_id}
            class={[
              sidebar_row_class(@node.current?),
              "min-w-0 flex-1 flex-row items-center gap-2",
              not @node.live? && "opacity-60"
            ]}
            title={workspace_home_title(@node, @home)}
          >
            <.sessions_sidebar_workspace_labels node={@node} />
          </.link>
        <% end %>
        <button
          :if={@expandable?}
          type="button"
          id={"sidebar-ws-toggle-" <> @node.dom_id}
          data-picker-ws-toggle
          phx-click="sidebar:toggle_workspace"
          phx-value-workspace-id={@node.workspace_id}
          class="flex shrink-0 items-center gap-density-label rounded px-1.5 font-mono text-density-label text-base-content/45 hover:bg-base-200 hover:text-base-content"
          aria-label={
            if(@node.expanded?, do: "Collapse " <> @node.label, else: "Expand " <> @node.label)
          }
          aria-expanded={to_string(@node.expanded?)}
          title={if(@node.expanded?, do: "Collapse sessions", else: "Expand sessions")}
        >
          {@node.session_count}
          <span class={[
            "flex transition-transform duration-motion-state ease-motion-state",
            @node.expanded? && "rotate-90"
          ]}>
            <.icon name="hero-chevron-right" class="size-3" />
          </span>
        </button>
      </div>
    <% else %>
      <%!-- No resolvable home session yet — typically a collapsed other workspace
           whose sessions haven't been lazy-loaded. Enter / a plain click still
           means "go": navigate to the workspace root and let the target mount
           pick its landing session (same gesture as dashboard folder:open).
           Expansion stays on the chevron, mirroring the resolved-home branch.
           Teammate rows (openable?: false) keep the legacy non-navigable
           expand/collapse toggle so the sidebar never links into another
           person's workspace. --%>
      <div :if={@openable?} class="flex items-stretch gap-0.5">
        <.link
          navigate={cross_workspace_home_path(@node.workspace_id)}
          data-picker-item
          data-picker-section="workspaces"
          data-picker-sessions-id={@node.dom_id}
          phx-value-workspace-id={@node.workspace_id}
          class={[
            sidebar_row_class(@node.current?),
            "min-w-0 flex-1 flex-row items-center gap-2",
            not @node.live? && "opacity-60"
          ]}
          title={workspace_home_title(@node, nil)}
        >
          <.sessions_sidebar_workspace_labels node={@node} />
        </.link>
        <button
          :if={@expandable?}
          type="button"
          id={"sidebar-ws-toggle-" <> @node.dom_id}
          data-picker-ws-toggle
          phx-click="sidebar:toggle_workspace"
          phx-value-workspace-id={@node.workspace_id}
          class="flex shrink-0 items-center gap-density-label rounded px-1.5 font-mono text-density-label text-base-content/45 hover:bg-base-200 hover:text-base-content"
          aria-label={
            if(@node.expanded?, do: "Collapse " <> @node.label, else: "Expand " <> @node.label)
          }
          aria-expanded={to_string(@node.expanded?)}
          title={if(@node.expanded?, do: "Collapse sessions", else: "Expand sessions")}
        >
          {@node.session_count}
          <span class={[
            "flex transition-transform duration-motion-state ease-motion-state",
            @node.expanded? && "rotate-90"
          ]}>
            <.icon name="hero-chevron-right" class="size-3" />
          </span>
        </button>
      </div>
      <button
        :if={not @openable?}
        type="button"
        data-picker-item
        data-picker-section="workspaces"
        data-picker-sessions-id={@node.dom_id}
        phx-click="sidebar:toggle_workspace"
        phx-value-workspace-id={@node.workspace_id}
        class={[
          sidebar_row_class(@node.current?),
          "flex-row items-center gap-2",
          not @node.live? && "opacity-60"
        ]}
        title={@node.title}
        aria-label={
          if(@node.expanded?, do: "Collapse " <> @node.label, else: "Expand " <> @node.label)
        }
        aria-expanded={to_string(@node.expanded?)}
      >
        <.sessions_sidebar_workspace_labels node={@node} />
        <span
          :if={@node.session_count > 0}
          class="flex shrink-0 items-center gap-density-label font-mono text-density-label text-base-content/45"
        >
          {@node.session_count}
          <span class={[
            "flex transition-transform duration-motion-state ease-motion-state",
            @node.expanded? && "rotate-90"
          ]}>
            <.icon name="hero-chevron-right" class="size-3" />
          </span>
        </span>
      </button>
    <% end %>
    """
  end

  attr :node, :map, required: true

  defp sessions_sidebar_workspace_labels(assigns) do
    assigns =
      assigns
      |> assign(:needs_you_count, Map.get(assigns.node, :needs_you_count, 0))
      # Separate unit from needs_you — never sum into Needs-you chip (#910).
      |> assign(:unseen_quiet_windows, Map.get(assigns.node, :unseen_quiet_windows, 0))

    ~H"""
    <span class="flex min-w-0 flex-1 flex-col items-start gap-0.5 overflow-hidden text-left">
      <span class="flex max-w-full items-center gap-1.5 overflow-hidden">
        <span data-picker-label class="truncate font-medium">{@node.label}</span>
        <span
          :if={@needs_you_count > 0}
          id={"sidebar-ws-needs-you-" <> @node.dom_id}
          data-needs-you-count={@needs_you_count}
          data-needs-you-sessions={@needs_you_count}
          class="shrink-0 rounded-full bg-status-danger/15 px-1.5 font-mono text-density-badge font-semibold text-status-danger-fg"
          title={needs_you_chip_title(@needs_you_count)}
          aria-label={needs_you_chip_title(@needs_you_count)}
        >
          {@needs_you_count}
        </span>
        <span
          :if={@unseen_quiet_windows > 0}
          id={"sidebar-ws-quiet-" <> @node.dom_id}
          data-unseen-quiet-windows={@unseen_quiet_windows}
          class="shrink-0 rounded-full bg-status-idle/15 px-1.5 font-mono text-density-badge font-semibold text-status-idle-fg"
          title={unseen_quiet_chip_title(@unseen_quiet_windows)}
          aria-label={unseen_quiet_chip_title(@unseen_quiet_windows)}
        >
          {@unseen_quiet_windows} quiet
        </span>
        <span
          :if={not @node.live?}
          class="size-1.5 shrink-0 rounded-full bg-base-content/25"
          title="No live tmux sessions"
        />
      </span>
      <span
        :if={@node.detail != ""}
        data-picker-label
        class="max-w-full truncate font-mono text-density-label text-base-content/50"
      >
        {@node.detail}
      </span>
    </span>
    """
  end

  # Landing/home session for a workspace node: the default shell when present,
  # else the first attachable session. nil when the node carries no sessions.
  defp workspace_home_session(%{sessions: sessions}, default_sid)
       when is_list(sessions) and sessions != [] do
    Enum.find(sessions, &(&1.id == default_sid)) || List.first(sessions)
  end

  defp workspace_home_session(_node, _default_sid), do: nil

  defp workspace_home_title(node, %{label: label}) when is_binary(label) and label != "",
    do: "Open home session (#{label}) — #{node.title}"

  defp workspace_home_title(node, _session), do: "Open #{node.label}"

  attr :node, :map, required: true
  attr :depth, :integer, default: 0

  defp sessions_sidebar_browse_node(assigns) do
    ~H"""
    <div
      data-picker-tree-branch
      data-picker-branch-id={@node.dom_id}
      data-browse-kind={@node.kind}
      data-browse-rel={@node.rel}
      class="flex flex-col gap-0.5"
      style={if(@depth > 0, do: "padding-left: #{@depth * 0.5}rem", else: nil)}
    >
      <div class="flex items-center gap-1 px-1">
        <button
          type="button"
          id={@node.dom_id}
          data-picker-item
          data-picker-section="browse"
          phx-click="sidebar:toggle_browse"
          phx-value-rel={@node.rel}
          class={[sidebar_row_class(false), "flex-row items-center gap-2"]}
          title={@node.title}
        >
          <span class={[
            "flex shrink-0 transition-transform duration-motion-state ease-motion-state",
            @node.expanded? && "rotate-90"
          ]}>
            <.icon name="hero-chevron-right" class="size-3 text-base-content/45" />
          </span>
          <span class="flex min-w-0 flex-1 flex-col items-start gap-0 overflow-hidden text-left">
            <span data-picker-label class="truncate font-medium">{@node.label}</span>
          </span>
        </button>
        <button
          :if={@node.kind == :browse_dir and is_binary(@node.path)}
          type="button"
          id={"sidebar-open-folder-" <> @node.dom_id}
          phx-click="sidebar:open_folder"
          phx-value-path={@node.path}
          class="shrink-0 rounded px-1.5 py-density-label font-mono text-density-label text-base-content/55 hover:bg-base-200 hover:text-base-content"
          title={"Open terminal in " <> @node.path}
          aria-label={"Open terminal in " <> @node.label}
        >
          term
        </button>
      </div>
      <div
        :if={is_list(@node.children)}
        data-picker-branch-children
        data-picker-collapsed={(!@node.expanded? && "") || nil}
        class={["space-y-0.5", !@node.expanded? && "hidden"]}
      >
        <%= if @node.children == [] do %>
          <p class="px-3 py-1 font-mono text-density-label italic text-base-content/40">
            No directories
          </p>
        <% else %>
          <%= for child <- @node.children do %>
            <.sessions_sidebar_browse_node node={child} depth={@depth + 1} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :workspace_id, :string, required: true
  attr :current_workspace_id, :string, required: true
  attr :active_id, :string, default: nil
  attr :default_sid, :string, default: nil
  attr :preview_panes, :map, default: %{}
  attr :path_base, :string, default: nil
  attr :parent_dom_id, :any, default: nil
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_session_id, :string, default: nil

  defp sessions_sidebar_session_row(assigns) do
    # Scratch is a synthetic workspaceless entry: always fire
    # `attach_terminal_session` with kind=scratch so the LiveView can
    # `push_navigate` to `/workspaces/__scratch__` (do not treat it as a
    # cross-workspace deep-link to a real session id).
    scratch? = Map.get(assigns.session, :kind) == :scratch

    cross_workspace? =
      not scratch? and assigns.workspace_id != assigns.current_workspace_id

    session_active? =
      not scratch? and assigns.active_id == assigns.session.id and not cross_workspace?

    href =
      Map.get(assigns.session, :href) ||
        sidebar_session_href(assigns.workspace_id, assigns.session.id)

    assigns =
      assigns
      |> assign(:cross_workspace?, cross_workspace?)
      |> assign(:session_active?, session_active?)
      |> assign(:href, href)

    ~H"""
    <div class="flex min-w-0 items-center gap-1 px-1">
      <%= if @cross_workspace? do %>
        <.link
          id={@session.dom_id}
          navigate={@href}
          data-picker-item
          data-picker-section="sessions"
          data-picker-parent={@parent_dom_id}
          data-agent-reference-kind="session"
          data-agent-reference-workspace-id={@workspace_id}
          data-agent-reference-session-id={@session.id}
          data-agent-reference-tmux-session={@session.tmux_session}
          data-agent-reference-label={@session.label}
          draggable="true"
          class={[sidebar_row_class(false), "min-w-0 flex-1"]}
          title={@session.title}
        >
          <.sessions_sidebar_session_labels
            session={@session}
            preview_panes={@preview_panes}
            default_sid={@default_sid}
          />
        </.link>
      <% else %>
        <a
          id={@session.dom_id}
          href={session_href(@workspace_id, @session.id, @path_base)}
          data-picker-item
          data-picker-section="sessions"
          data-picker-active={@session_active? || nil}
          data-picker-parent={@parent_dom_id}
          phx-click="attach_terminal_session"
          phx-value-session-id={@session.id}
          phx-value-kind={Atom.to_string(@session.kind)}
          phx-value-tmux-session={@session.tmux_session}
          data-agent-reference-kind="session"
          data-agent-reference-workspace-id={@workspace_id}
          data-agent-reference-session-id={@session.id}
          data-agent-reference-tmux-session={@session.tmux_session}
          data-agent-reference-label={@session.label}
          draggable="true"
          class={[sidebar_row_class(@session_active?), "min-w-0 flex-1"]}
          title={@session.title}
        >
          <.sessions_sidebar_session_labels
            session={@session}
            preview_panes={@preview_panes}
            default_sid={@default_sid}
          />
        </a>
      <% end %>
      <.copy_link_button
        url={
          if(@cross_workspace?,
            do: session_share_url_from_href(@href),
            else: session_share_url(@workspace_id, @session.id, @path_base)
          )
        }
        label={@session.label}
        visible?={false}
      />
      <%= if @mutations_allowed? and not @cross_workspace? and is_binary(@session.tmux_session) and
              @session.tmux_session != "" and @rename_session_id == @session.id do %>
        <.form
          for={to_form(%{}, as: :session)}
          id={"session-rename-form-" <> @session.dom_id}
          phx-submit="terminal:rename_session"
          class="flex items-center gap-1 px-1"
        >
          <input type="hidden" name="session[id]" value={@session.id} />
          <input type="hidden" name="session[tmux_session]" value={@session.tmux_session} />
          <input
            type="text"
            id={"session-rename-input-" <> @session.dom_id}
            name="session[name]"
            value={@session.label}
            phx-hook="RenameInput"
            phx-keydown="terminal:rename_session_cancel"
            phx-key="Escape"
            autocomplete="off"
            class="h-6 w-24 rounded border border-base-300 bg-base-100 px-2 py-0 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
          />
          <button
            type="submit"
            class="rounded p-1 text-primary hover:bg-primary/10"
            title="Save session name"
          >
            <.icon name="hero-check" class="size-3" />
          </button>
          <button
            type="button"
            phx-click="terminal:rename_session_cancel"
            class="rounded p-1 text-base-content/45 hover:bg-base-200"
            title="Cancel rename"
          >
            <.icon name="hero-x-mark" class="size-3" />
          </button>
        </.form>
      <% end %>
    </div>
    """
  end

  attr :session, :map, required: true
  attr :preview_panes, :map, default: %{}
  attr :default_sid, :string, default: nil

  defp sessions_sidebar_session_labels(assigns) do
    assigns = assign(assigns, :agent_badge, session_agent_badge(assigns.session))

    ~H"""
    <%!-- nowrap sizes the free-expand rail; nav overflow clips past max-width. --%>
    <span class="flex max-w-full items-center gap-1.5 overflow-hidden">
      <span
        :if={@session.id == @default_sid}
        class="flex shrink-0 text-base-content/55"
        title="Home session — your landing shell"
        aria-label="Home session"
      >
        <.icon name="hero-home" class="size-3" />
      </span>
      <span data-picker-label class="truncate font-medium">{@session.label}</span>
      <.session_anchor_chip tab={@session} />
      <.preview_badge
        count={preview_pane_count(@session.pane_ids, @preview_panes)}
        id={"sidebar-session-preview-" <> @session.dom_id}
        scope="session"
      />
      <span
        :if={@agent_badge}
        id={"session-agent-badge-" <> @session.dom_id}
        data-agent-attention={@agent_badge.reason}
        class={["shrink-0 rounded-full px-1.5 text-density-badge font-semibold", @agent_badge.class]}
        title={@agent_badge.title}
        aria-label={@agent_badge.title}
      >
        {@agent_badge.text}
      </span>
      <span
        :if={@session.quiet_count > 0}
        data-attention={@session.attention}
        class={["shrink-0", quiet_badge_class(@session.attention)]}
        title={quiet_badge_label(@session.quiet_count, @session.unseen_quiet_count)}
        aria-label={quiet_badge_label(@session.quiet_count, @session.unseen_quiet_count)}
      />
      <span
        :if={@session.quiet_count == 0 and Map.get(@session, :activity_state) != :idle}
        data-activity-state={@session.activity_state}
        class={["size-1.5 shrink-0 rounded-full", @session.activity_class]}
        title={@session.activity_label}
        aria-label={@session.activity_label}
      />
    </span>
    <%!-- Second line, matching the workspace rows: session labels alone repeat
    across workspaces, so the cwd/branch detail is what tells two "shell" rows
    apart. Kept out of `data-picker-label` so type-to-filter still matches on
    the name only. --%>
    <span
      :if={session_detail(@session) != ""}
      class="max-w-full truncate font-mono text-density-label text-base-content/60"
    >
      {session_detail(@session)}
    </span>
    """
  end

  defp session_detail(session) do
    case Map.get(session, :detail) do
      detail when is_binary(detail) -> detail
      _ -> ""
    end
  end

  attr :node, :map, required: true
  attr :workspace_id, :string, required: true
  attr :terminal_sid, :string, default: nil
  attr :path_base, :string, default: nil
  attr :parent_dom_id, :any, default: nil
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_window_id, :string, default: nil

  defp window_sidebar_window_row(assigns) do
    ~H"""
    <div
      id={"tmux-window-sidebar-" <> @node.dom_frag}
      data-ctx-menu="window_tab"
      data-ctx-window-id={@node.id}
      class="px-1"
    >
      <.window_sidebar_window_link
        node={@node}
        workspace_id={@workspace_id}
        terminal_sid={@terminal_sid}
        path_base={@path_base}
        parent_dom_id={@parent_dom_id}
        class={[sidebar_row_class(@node.active?), "w-full"]}
      />
      <%= if @mutations_allowed? and @rename_window_id == @node.id do %>
        <.window_inline_rename_form
          window={@node}
          id_suffix="-sidebar"
          form_class="flex items-center gap-1 px-1"
          input_class="h-6 min-w-0 flex-1 rounded border border-base-300 bg-base-100 px-1.5 text-xs"
          show_cancel?={false}
        />
      <% end %>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :workspace_id, :string, required: true
  attr :terminal_sid, :string, default: nil
  attr :path_base, :string, default: nil
  attr :parent_dom_id, :any, default: nil
  attr :class, :any, default: nil

  defp window_sidebar_window_link(assigns) do
    ~H"""
    <a
      href={window_href(@workspace_id, @terminal_sid, @node.id, path_base: @path_base)}
      data-picker-item
      data-picker-section="windows"
      data-picker-branch-id={@node.dom_id}
      data-picker-active={@node.active? || nil}
      data-picker-parent={@parent_dom_id}
      data-agent-reference-kind="window"
      data-agent-reference-workspace-id={@workspace_id}
      data-agent-reference-session-id={@terminal_sid}
      data-agent-reference-window-id={@node.id}
      data-agent-reference-window-index={@node.index}
      data-agent-reference-label={@node.display_name}
      draggable="true"
      phx-click="tmux:select_window"
      phx-value-window-id={@node.id}
      data-tmux-window-index={@node.index}
      class={@class}
      title={"Select tmux window " <> @node.full_title}
    >
      <span class="flex min-w-0 max-w-full items-center gap-1.5">
        <.window_row_name
          window={@node}
          picker_label?
          name_class="min-w-0 truncate font-medium"
        />
        <.window_row_indicators window={@node} preview_aria_hidden? />
      </span>
    </a>
    """
  end

  attr :pane, :map, required: true
  attr :window_id, :string, required: true
  attr :workspace_id, :string, required: true
  attr :terminal_sid, :string, default: nil
  attr :path_base, :string, default: nil
  attr :parent_dom_id, :string, required: true

  defp window_sidebar_pane_row(assigns) do
    ~H"""
    <a
      id={"sidebar-pane-" <> @pane.dom_frag}
      href={
        window_href(@workspace_id, @terminal_sid, @window_id,
          path_base: @path_base,
          pane: @pane.id
        )
      }
      data-picker-item
      data-picker-section="panes"
      data-picker-parent={@parent_dom_id}
      data-picker-active={@pane.active? || nil}
      phx-click="tmux:select_pane"
      phx-value-pane-id={@pane.id}
      phx-value-window-id={@window_id}
      class={sidebar_row_class(@pane.active?)}
      title={@pane.title}
    >
      <span class="flex min-w-0 max-w-full items-center gap-1.5">
        <span class="shrink-0 font-mono text-density-label text-base-content/45">{@pane.index}</span>
        <span data-picker-label class="min-w-0 truncate font-medium">{@pane.label}</span>
        <span
          :if={@pane.preview?}
          class="inline-flex size-3.5 shrink-0 items-center justify-center rounded bg-status-live/15 text-status-live-fg ring-1 ring-status-live/30"
          title="Preview pane"
          aria-label="Preview pane"
        >
          <.icon name="hero-globe-alt" class="size-2.5" />
        </span>
        <span
          :if={not @pane.preview? and window_agent_chip_text(@pane)}
          data-agent-state={Map.get(@pane, :agent_state)}
          class={[
            "shrink-0 rounded-full px-1 text-[9px] font-semibold",
            window_agent_chip_class(@pane)
          ]}
          title={@pane.activity_label}
          aria-label={@pane.activity_label}
        >
          {window_agent_chip_text(@pane)}
        </span>
        <span
          :if={not @pane.preview?}
          data-activity-state={@pane.activity_state}
          data-agent-state={Map.get(@pane, :agent_state)}
          class={["size-1.5 shrink-0 rounded-full", @pane.activity_class]}
          title={@pane.activity_label}
          aria-label={@pane.activity_label}
        />
      </span>
    </a>
    """
  end

  attr :workspace_id, :string, required: true
  attr :tabs, :list, required: true
  attr :active_id, :string, default: nil
  attr :active_fallback_label, :string, default: "session"
  attr :active_fallback_detail, :string, default: ""
  attr :open?, :boolean, default: false, doc: "sessions rail currently open"

  def session_header_indicator(assigns) do
    ~H"""
    <button
      type="button"
      id={"session-header-indicator-" <> @workspace_id}
      phx-click="sidebar:toggle_sessions"
      data-shortcut="Ctrl + B, then S"
      data-leader-second-key="S"
      class={[
        "leader-key-control relative flex shrink-0 items-center gap-1.5 rounded border px-1.5 py-0.5 text-xs transition max-sm:hidden",
        @open? && "border-primary/50 bg-primary/10 text-primary",
        !@open? &&
          "border-transparent text-base-content/80 hover:border-base-300 hover:bg-base-200 hover:text-base-content"
      ]}
      title={
        active_session_picker_title(
          @tabs,
          @active_id,
          @active_fallback_label,
          @active_fallback_detail
        )
      }
      aria-label={
        if(@open?,
          do: "Close sessions sidebar",
          else: "Open sessions sidebar"
        )
      }
      aria-expanded={to_string(@open?)}
      aria-pressed={to_string(@open?)}
    >
      <% summary_label = active_session_label(@tabs, @active_id, @active_fallback_label) %>
      <span class="max-w-[7rem] truncate font-medium sm:max-w-52">
        <span class="header-p-min-full">{summary_label}</span>
        <span class="header-p-min-short" title={summary_label}>
          {session_picker_short_label(summary_label)}
        </span>
      </span>
      <span
        :if={quiet_window_count(@tabs) > 0}
        id={"session-quiet-badge-" <> @workspace_id}
        data-attention={quiet_badge_attention(@tabs)}
        class={quiet_badge_class(quiet_badge_attention(@tabs))}
        title={quiet_badge_label(quiet_window_count(@tabs), unseen_quiet_window_count(@tabs))}
        aria-label={quiet_badge_label(quiet_window_count(@tabs), unseen_quiet_window_count(@tabs))}
      ></span>
      <.icon
        name={if(@open?, do: "hero-chevron-left", else: "hero-chevron-right")}
        class="size-3.5 shrink-0 opacity-60"
      />
    </button>
    """
  end

  attr :workspace_id, :string, required: true
  attr :tree, :list, required: true, doc: "SessionBarVM.window_tree/2 nodes"
  attr :terminal_sid, :string, default: nil
  attr :topology_version, :integer, default: 0
  attr :mutations_allowed?, :boolean, required: true
  attr :rename_window_id, :string, default: nil
  attr :path_base, :string, default: nil
  attr :sort_mode, :atom, default: :recency

  attr :class, :any,
    default: nil,
    doc: "layout classes — desktop-only rail beside the terminal body"

  def window_sidebar(assigns) do
    ~H"""
    <nav
      :if={@tree != []}
      id={"window-sidebar-" <> @workspace_id}
      data-window-picker-sidebar="true"
      data-version={@topology_version}
      data-shortcut="Ctrl + B, then W"
      data-leader-second-key="W"
      phx-hook="WindowPickerSidebar"
      aria-label="Tmux windows and panes"
      class={
        [
          # Fixed rail width + opaque bg so Windows never paints over Sessions.
          "window-picker-sidebar leader-key-control relative z-[1] flex w-72 max-w-[42vw] shrink-0 flex-col overflow-hidden border-r border-base-300/70 bg-base-100",
          @class
        ]
      }
    >
      <div
        data-ctx-menu="windows_rail"
        class="flex shrink-0 items-center justify-between gap-1.5 border-b border-base-300/70 px-3 py-1.5"
      >
        <span class="text-density-body font-semibold tracking-wide text-base-content/70">
          Windows
        </span>
        <button
          type="button"
          phx-click="sidebar:cycle_windows_sort"
          class="flex items-center gap-1 rounded border border-base-300/70 px-1.5 py-density-label text-density-label text-base-content/70 hover:bg-base-200 hover:text-base-content"
          title={"Sorted by " <> SessionBarVM.sort_mode_label(@sort_mode) <> " — click to cycle"}
          aria-label={"Sorted by " <> SessionBarVM.sort_mode_label(@sort_mode) <> ", click to cycle"}
        >
          <.icon name="hero-bars-arrow-down" class="size-3" />
          {SessionBarVM.sort_mode_label(@sort_mode)}
        </button>
      </div>
      <div class="flex shrink-0 items-center gap-1.5 border-b border-base-300/70 px-2 py-1">
        <.icon name="hero-funnel" class="size-3 shrink-0 text-base-content/50" />
        <span
          data-picker-filter
          data-picker-filter-placeholder="Type to filter"
          data-picker-filter-empty
          class="min-w-0 truncate font-mono text-density-body text-base-content/75"
        >
          Type to filter
        </span>
      </div>
      <div class="min-h-0 min-w-0 w-full flex-1 overflow-y-auto overflow-x-hidden px-1 py-1.5">
        <%= for node <- @tree do %>
          <%= cond do %>
            <% node.flat_window? -> %>
              <.window_sidebar_window_row
                node={node}
                workspace_id={@workspace_id}
                terminal_sid={@terminal_sid}
                path_base={@path_base}
                parent_dom_id={nil}
                mutations_allowed?={@mutations_allowed?}
                rename_window_id={@rename_window_id}
              />
            <% node.pane_count > 1 -> %>
              <div
                id={"tmux-window-sidebar-" <> node.dom_frag}
                data-ctx-menu="window_tab"
                data-ctx-window-id={node.id}
                data-picker-tree-branch
                data-picker-branch-id={node.dom_id}
                class="flex flex-col gap-0.5"
              >
                <div class="flex min-w-0 items-center gap-1 px-1">
                  <.window_sidebar_window_link
                    node={node}
                    workspace_id={@workspace_id}
                    terminal_sid={@terminal_sid}
                    path_base={@path_base}
                    parent_dom_id={nil}
                    class={[sidebar_row_class(node.active?), "min-w-0 flex-1"]}
                  />
                  <button
                    type="button"
                    tabindex="-1"
                    phx-click="sidebar:toggle_window"
                    phx-value-window-id={node.id}
                    class="flex shrink-0 items-center gap-density-label rounded px-1.5 py-1 font-mono text-density-label text-base-content/45 hover:bg-base-200"
                    aria-label={
                      if(node.expanded?,
                        do: "Collapse panes of " <> node.display_name,
                        else: "Expand panes of " <> node.display_name
                      )
                    }
                  >
                    {node.pane_count}
                    <span class={[
                      "flex transition-transform duration-motion-state ease-motion-state",
                      node.expanded? && "rotate-90"
                    ]}>
                      <.icon name="hero-chevron-right" class="size-3" />
                    </span>
                  </button>
                </div>
                <%= if @mutations_allowed? and @rename_window_id == node.id do %>
                  <.window_inline_rename_form
                    window={node}
                    id_suffix="-sidebar"
                    form_class="flex items-center gap-1 px-1"
                    input_class="h-6 min-w-0 flex-1 rounded border border-base-300 bg-base-100 px-1.5 text-xs"
                    show_cancel?={false}
                  />
                <% end %>
                <div
                  id={"sidebar-window-panes-" <> node.dom_frag}
                  data-picker-branch-children
                  data-picker-collapsed={(!node.expanded? && "") || nil}
                  class={["space-y-0.5 pl-3", !node.expanded? && "hidden"]}
                >
                  <%= for pane <- node.panes || [] do %>
                    <.window_sidebar_pane_row
                      pane={pane}
                      window_id={node.id}
                      workspace_id={@workspace_id}
                      terminal_sid={@terminal_sid}
                      path_base={@path_base}
                      parent_dom_id={node.dom_id}
                    />
                  <% end %>
                </div>
              </div>
          <% end %>
        <% end %>
      </div>
      <div class="flex shrink-0 items-center justify-between gap-1 border-t border-base-300/70 px-2 py-1.5">
        <span class="min-w-0 truncate font-mono text-density-label text-base-content/60">
          o open · l link · r rename · &amp; kill
        </span>
        <button
          :if={@mutations_allowed?}
          type="button"
          phx-click="tmux:new_window"
          class="flex shrink-0 items-center rounded p-1 text-base-content/60 hover:bg-base-200 hover:text-base-content"
          title="New window · Ctrl + B c"
          aria-label="New tmux window"
        >
          <.icon name="hero-plus" class="size-3.5" />
        </button>
      </div>
    </nav>
    """
  end

  @doc """
  Sky "preview running" badge — the same symbol the window picker shows on a
  window hosting a live preview pane. Renders nothing when `count` is zero.
  """
  attr :count, :integer, required: true
  attr :id, :string, required: true
  attr :scope, :string, default: "window", doc: "\"session\" or \"window\" — tooltip wording only"

  def preview_badge(assigns) do
    ~H"""
    <span
      :if={@count > 0}
      id={@id}
      data-preview-running="true"
      data-preview-count={@count}
      class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-status-live/15 text-status-live-fg ring-1 ring-status-live/30"
      title={preview_badge_label(@scope, @count)}
      aria-label={preview_badge_label(@scope, @count)}
    >
      <.icon name="hero-globe-alt" class="size-3" />
    </span>
    """
  end

  defp preview_badge_label(scope, count) do
    "Preview pane running in this #{scope} (#{count})"
  end

  @doc """
  Branch/worktree anchor chip for a session row. For a worktree it reads
  "repo⑂branch" — the repo a worktree cwd descends from is otherwise invisible;
  a plain checkout on a feature branch shows the branch alone. Renders nothing
  for an uninteresting branch (default branch on the primary checkout).
  """
  attr :tab, :map, required: true

  def session_anchor_chip(assigns) do
    ~H"""
    <span
      :if={session_anchor_interesting?(@tab)}
      class="inline-flex min-w-0 shrink items-center gap-density-label rounded bg-base-200 px-1 font-mono text-density-label text-base-content/55"
      title={session_anchor_title(@tab)}
    >
      <.icon name="hero-arrows-right-left" class="size-2.5 shrink-0" />
      <span
        :if={Map.get(@tab, :worktree?) and Map.get(@tab, :repo, "") != ""}
        class="shrink-0 text-base-content/40"
      >
        {@tab.repo}⑂
      </span>
      <span class="max-w-32 truncate">{branch_short(@tab.branch)}</span>
    </span>
    """
  end

  @doc """
  Whether a session's branch is worth surfacing as an anchor chip: always for a
  worktree, otherwise only when the branch isn't the repo's default. Keeps
  `master`/`main` on a primary checkout from becoming per-row noise.
  """
  def session_anchor_interesting?(tab) when is_map(tab) do
    branch = Map.get(tab, :branch, "")

    is_binary(branch) and branch != "" and
      (Map.get(tab, :worktree?, false) or not default_branch?(branch))
  end

  def session_anchor_interesting?(_), do: false

  @doc """
  The distinguishing tail of a branch name — `agent/grok/fix-thing` → `fix-thing`.
  The shared `agent/grok/` prefix repeats across worktrees and only steals width;
  the full name still reaches the hover title via `session_anchor_title/1`.
  """
  defdelegate branch_short(branch), to: SessionBarVM

  defp default_branch?(branch), do: SessionBarVM.default_branch?(branch)

  defp session_anchor_title(%{worktree?: true, repo: repo, branch: branch})
       when is_binary(repo) and repo != "" do
    "Worktree of " <> repo <> " · branch " <> branch
  end

  defp session_anchor_title(%{branch: branch}) when is_binary(branch) and branch != "" do
    "Branch " <> branch
  end

  defp session_anchor_title(_), do: nil

  # Counts how many of a session/window's panes currently host a live preview
  # by joining its pane ids against the workspace preview registry.
  defp preview_pane_count(pane_ids, preview_panes)
       when is_list(pane_ids) and is_map(preview_panes) do
    Enum.count(pane_ids, &Map.has_key?(preview_panes, &1))
  end

  defp preview_pane_count(_pane_ids, _preview_panes), do: 0

  defp terminal_tab_class(true),
    do:
      "flex max-w-56 shrink-0 flex-col items-start rounded border border-primary bg-primary/10 px-2.5 py-1 text-left text-xs leading-tight text-primary transition"

  defp terminal_tab_class(false),
    do:
      "flex max-w-56 shrink-0 flex-col items-start rounded border border-base-300 px-2.5 py-1 text-left text-xs leading-tight text-base-content/70 transition hover:bg-base-200 hover:text-base-content"

  defp sidebar_row_class(true),
    do:
      "flex w-full max-w-full min-w-0 flex-col items-start gap-0.5 overflow-hidden rounded border border-primary/40 bg-primary/10 px-2.5 py-1.5 text-left text-xs leading-snug text-primary"

  defp sidebar_row_class(false),
    do:
      "flex w-full max-w-full min-w-0 flex-col items-start gap-0.5 overflow-hidden rounded px-2.5 py-1.5 text-left text-xs leading-snug text-base-content/80 hover:bg-base-200"

  defp sidebar_session_href(workspace_id, session_id)
       when is_binary(workspace_id) and is_binary(session_id) do
    "/workspaces/#{workspace_id}?session=#{URI.encode_www_form(session_id)}"
  end

  @doc """
  Relative navigate path for a cross-workspace session row.

  Prefers the session's precomputed `:href` (set for other-workspace summary
  tabs) and falls back to the `?session=` deep-link. Public so the mobile nav
  sheet can reuse the exact same target the desktop sidebar navigates to.
  """
  @spec cross_workspace_session_path(String.t(), map()) :: String.t()
  def cross_workspace_session_path(workspace_id, session) when is_map(session) do
    Map.get(session, :href) || sidebar_session_href(workspace_id, Map.get(session, :id))
  end

  @doc """
  Relative navigate path for a workspace row whose home session is not yet
  resolvable (sessions not lazy-loaded). Targets the workspace root; the
  target mount picks the landing session. Public so the mobile nav sheet
  navigates to the exact same place as the desktop sidebar.
  """
  @spec cross_workspace_home_path(String.t()) :: String.t()
  def cross_workspace_home_path(workspace_id) when is_binary(workspace_id),
    do: WorkspaceRoutes.workspace_path(workspace_id, "local")

  defp session_picker_short_label(label) when is_binary(label) do
    label
    |> String.split(~r/\s+/, trim: true)
    |> List.first()
    |> case do
      nil ->
        "…"

      word ->
        # Path-like labels (cwd "owner/repo") repeat the owner across every
        # workspace — surface the distinguishing tail, not the prefix.
        word
        |> String.split("/", trim: true)
        |> List.last()
        |> clamp_short_label()
    end
  end

  defp clamp_short_label(nil), do: "…"
  defp clamp_short_label(word) when byte_size(word) > 9, do: String.slice(word, 0, 9) <> "…"
  defp clamp_short_label(word), do: word

  defp active_session_label(tabs, active_id, fallback_label) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      nil -> fallback_label
      tab -> tab_anchor_label(tab)
    end
  end

  defp active_session_detail(tabs, active_id, fallback_detail) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      nil -> fallback_detail
      tab -> tab_anchor_detail(tab)
    end
  end

  defp active_session_cwd(tabs, active_id) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{cwd: cwd} when is_binary(cwd) and cwd != "" -> cwd
      _ -> nil
    end
  end

  # The cwd is part of the tooltip, not decoration: the visible label is the
  # origin-first `repo ⑂ branch` form, so this is the only place the actual
  # worktree directory is still spelled out.
  defp active_session_picker_title(tabs, active_id, fallback_label, fallback_detail) do
    session =
      [
        active_session_label(tabs, active_id, fallback_label),
        active_session_cwd(tabs, active_id),
        active_session_detail(tabs, active_id, fallback_detail)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.join(" · ")

    "Active session: " <>
      session <> ". Click to open sessions. Shortcut: Ctrl + B, then S"
  end

  # Surfaces that render a session label alone — with no `session_anchor_chip/1`
  # beside it — need the origin folded into the text itself. `anchor_label` is
  # that form; tab-shaped maps built without it fall back to the plain label.
  defp tab_anchor_label(tab) when is_map(tab) do
    case Map.get(tab, :anchor_label) do
      label when is_binary(label) and label != "" -> label
      _ -> Map.get(tab, :label) || ""
    end
  end

  # Pairs with `tab_anchor_label/1`. Once the label carries the branch tail, the
  # detail line must drop the branch or it renders twice — which is what
  # `detail_secondary` is for.
  defp tab_anchor_detail(tab) when is_map(tab) do
    detail = Map.get(tab, :detail) || ""

    if anchored?(tab) do
      Map.get(tab, :detail_secondary) || detail
    else
      detail
    end
  end

  defp anchored?(tab), do: tab_anchor_label(tab) != (Map.get(tab, :label) || "")

  attr :url, :string, required: true
  attr :label, :string, required: true
  attr :kind, :string, default: "session"
  attr :agent_url, :string, default: nil
  attr :visible?, :boolean, default: false

  def copy_link_button(assigns) do
    ~H"""
    <button
      type="button"
      tabindex="-1"
      data-copy-session-link={@url}
      data-copy-session-link-agent={@agent_url}
      data-copy-link-kind={@kind}
      class={[
        "shrink-0 rounded p-1 transition-opacity duration-motion-state ease-motion-state hover:bg-base-300/60",
        @visible? && "opacity-100",
        !@visible? && "opacity-0 group-hover:opacity-100"
      ]}
      title={copy_link_title(@label, @agent_url)}
      aria-label={"Copy link to " <> @label}
    >
      <.icon name="hero-link" class="size-3" />
    </button>
    """
  end

  defp copy_link_title(label, agent_url) when is_binary(agent_url) and agent_url != "",
    do: "Copy link to " <> label <> " (Ctrl/⌘-click copies the agent MCP link)"

  defp copy_link_title(label, _agent_url), do: "Copy link to " <> label

  @doc """
  Absolute terminal MCP endpoint URL pre-scoped to this workspace and tmux session.

  This is the agent-facing handle (workspace_id + tmux_session) another agent can
  point its MCP client at, distinct from the human viewer `?session=` share link.
  Returns nil when there is no concrete tmux session to scope to.
  """
  @spec agent_mcp_url(String.t(), String.t() | nil) :: String.t() | nil
  def agent_mcp_url(workspace_id, tmux_session)
      when is_binary(workspace_id) and workspace_id != "" and
             is_binary(tmux_session) and tmux_session != "" do
    Casein.Agents.MCPUrls.terminal_url(workspace_id, tmux_session: tmux_session)
  end

  def agent_mcp_url(_workspace_id, _tmux_session), do: nil

  @doc "Absolute share URL for the workspace session, optionally pinned to a window/pane/zoom."
  @spec share_url(String.t(), String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def share_url(workspace_id, session_id, window_id \\ nil, opts \\ [])

  def share_url(workspace_id, session_id, window_id, opts)
      when is_binary(workspace_id) and is_binary(session_id) and session_id != "" and
             is_binary(window_id) and window_id != "" do
    CaseinWeb.Endpoint.url() <> session_window_href(workspace_id, session_id, window_id, opts)
  end

  def share_url(workspace_id, session_id, _window_id, opts)
      when is_binary(workspace_id) and is_binary(session_id) and session_id != "" do
    CaseinWeb.Endpoint.url() <> session_href(workspace_id, session_id, opts[:path_base])
  end

  def share_url(_workspace_id, _session_id, _window_id, _opts), do: nil

  defp workspace_href(workspace_id, path_base), do: path_base(workspace_id, path_base)

  defp session_href(workspace_id, session_id, path_base),
    do: query_href(path_base(workspace_id, path_base), session: session_id)

  defp session_share_url(workspace_id, session_id, path_base),
    do: share_url(workspace_id, session_id, nil, path_base: path_base)

  defp session_share_url_from_href(href) when is_binary(href) and href != "" do
    CaseinWeb.Endpoint.url() <> href
  end

  defp window_href(workspace_id, window_id, opts) when is_list(opts),
    do: query_href(path_base(workspace_id, opts[:path_base]), window: window_id)

  # Preserve the active (non-default) session when switching windows so a bare
  # <a href> navigation (e.g. a mobile tap that beats the phx-click push) doesn't
  # land on `?window=X` with no session and get reset to the default session.
  defp window_href(workspace_id, session_id, window_id),
    do: window_href(workspace_id, session_id, window_id, [])

  defp window_href(workspace_id, session_id, window_id, opts)
       when is_binary(session_id) and session_id != "",
       do: session_window_href(workspace_id, session_id, window_id, opts)

  defp window_href(workspace_id, _session_id, window_id, opts),
    do: window_href(workspace_id, window_id, opts)

  defp session_window_href(workspace_id, session_id, window_id, opts) do
    pane = Keyword.get(opts, :pane)
    zoom? = Keyword.get(opts, :zoom) == true
    path_base = Keyword.get(opts, :path_base)

    query =
      %{
        "session" => session_id,
        "window" => window_id,
        "pane" => if(zoom? or is_binary(pane), do: pane, else: nil),
        "zoom" => if(zoom?, do: "1")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> URI.encode_query()

    query_href(path_base(workspace_id, path_base), query)
  end

  defp path_base(_workspace_id, path_base) when is_binary(path_base) and path_base != "",
    do: path_base

  defp path_base(workspace_id, _path_base), do: "/workspaces/#{workspace_id}"

  defp query_href(base, params) when is_list(params) or is_map(params) do
    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> URI.encode_query()
    |> then(&query_href(base, &1))
  end

  defp query_href(base, ""), do: base
  defp query_href(base, query), do: base <> "?" <> query

  defp quiet_window_count(tabs) when is_list(tabs) do
    Enum.reduce(tabs, 0, fn tab, total ->
      total + Map.get(tab, :quiet_count, 0)
    end)
  end

  defp quiet_window_count(_tabs), do: 0

  defp unseen_quiet_window_count(tabs) when is_list(tabs) do
    Enum.reduce(tabs, 0, fn tab, total ->
      total + Map.get(tab, :unseen_quiet_count, 0)
    end)
  end

  defp unseen_quiet_window_count(_tabs), do: 0

  defp quiet_badge_attention(tabs) do
    Casein.Attention.Delivery.chrome_attention_label(
      unseen_quiet_window_count(tabs),
      quiet_window_count(tabs)
    )
  end

  defp quiet_badge_class("unseen") do
    "size-2 shrink-0 rounded-full bg-fuchsia-400 shadow-[0_0_0_4px_rgba(217,70,239,0.24)] ring-1 ring-fuchsia-200/80"
  end

  defp quiet_badge_class(_attention) do
    "size-1.5 shrink-0 rounded-full bg-status-idle shadow-[0_0_0_3px_color-mix(in_oklch,var(--color-status-idle)_25%,transparent)]"
  end

  defp quiet_badge_label(_quiet_count, 1), do: "1 unseen quiet agent window"

  defp quiet_badge_label(_quiet_count, unseen_count) when unseen_count > 1,
    do: "#{unseen_count} unseen quiet agent windows"

  defp quiet_badge_label(1, _unseen_count), do: "1 quiet agent window"
  defp quiet_badge_label(count, _unseen_count), do: "#{count} quiet agent windows"

  # Textual triage badge for a session row's semantic agent state. Quiet-only
  # attention keeps its existing dot badge; nil means nothing extra to render.
  # Colours come from daisyUI semantic tokens (shared with AgentStateChrome /
  # #729) — do not invent a second palette here.
  defp session_agent_badge(session) do
    if Map.get(session, :attention_section) == :needs_you do
      agent_badge_for_reason(Map.get(session, :attention_reason), session)
    end
  end

  # Chip text from SessionBarVM.attention_chip_label/1 only (#910 catalogue).
  # Stalled stays distinct from idle/Quiet update (AgentProgress taxonomy).
  defp agent_badge_for_reason(:blocked, session) do
    count = Map.get(session, :agent_blocked_count, 0)
    chip = SessionBarVM.attention_chip_label(:blocked)

    base =
      if(count > 1,
        do: "#{count} agent windows need input",
        else: "Needs input"
      )

    %{
      reason: :blocked,
      class: "bg-error/15 text-error",
      text: if(count > 1, do: "#{chip} ×#{count}", else: chip),
      title: with_attention_message(base, session)
    }
  end

  defp agent_badge_for_reason(:awaiting_input, session) do
    chip = SessionBarVM.attention_chip_label(:awaiting_input)

    %{
      reason: :awaiting_input,
      class: "bg-error/15 text-error",
      text: chip,
      title: with_attention_message("Needs input", session)
    }
  end

  defp agent_badge_for_reason(:errored, session) do
    count = Map.get(session, :agent_blocked_count, 0)
    chip = SessionBarVM.attention_chip_label(:errored)

    %{
      reason: :errored,
      class: "bg-error/15 text-error",
      text: if(count > 1, do: "#{chip} ×#{count}", else: chip),
      title: with_attention_message("Error", session)
    }
  end

  defp agent_badge_for_reason(:stalled, session) do
    count = Map.get(session, :agent_blocked_count, 0)
    chip = SessionBarVM.attention_chip_label(:stalled)

    %{
      reason: :stalled,
      class: "bg-warning/15 text-warning",
      text: if(count > 1, do: "#{chip} ×#{count}", else: chip),
      title:
        with_attention_message(
          "Stalled — running but not progressing (not idle)",
          session
        )
    }
  end

  defp agent_badge_for_reason(:completed, session) do
    chip = SessionBarVM.attention_chip_label(:completed)

    %{
      reason: :completed,
      class: "bg-info/15 text-info",
      text: chip,
      title: with_attention_message("Finished — review result", session)
    }
  end

  defp agent_badge_for_reason(:idle, session) do
    chip = SessionBarVM.attention_chip_label(:idle)

    %{
      reason: :idle,
      class: "bg-base-content/10 text-base-content/70",
      text: chip,
      title: with_attention_message("Quiet update", session)
    }
  end

  defp agent_badge_for_reason(:error, _session) do
    chip = SessionBarVM.attention_chip_label(:error)

    %{
      reason: :error,
      class: "bg-error/15 text-error",
      text: chip,
      title: "Error"
    }
  end

  defp agent_badge_for_reason(_reason, _session), do: nil

  # Append the agent's own status message to a badge tooltip when one is present
  # on the tab, so hovering tells you *why* it needs you, not just that it does.
  defp with_attention_message(base, session) do
    case Map.get(session, :attention_message) do
      message when is_binary(message) and message != "" -> base <> " — " <> message
      _ -> base
    end
  end

  # Sessions only — never include unseen quiet windows in this string (#910).
  defp needs_you_chip_title(1), do: "1 session needs you"
  defp needs_you_chip_title(count), do: "#{count} sessions need you"

  defp unseen_quiet_chip_title(1), do: "1 unseen quiet agent window"
  defp unseen_quiet_chip_title(count), do: "#{count} unseen quiet agent windows"
end
