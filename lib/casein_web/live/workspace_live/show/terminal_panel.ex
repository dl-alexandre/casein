defmodule CaseinWeb.WorkspaceLive.Show.TerminalPanel do
  @moduledoc false

  use CaseinWeb, :html
  import CaseinWeb.WorkspaceLive.Show.TerminalChrome

  alias Casein.Workspaces
  alias CaseinWeb.WorkspaceLive.Show.SessionBar
  alias CaseinWeb.WorkspaceLive.Show.SessionBarVM

  attr :active_window_pane_count, :any, required: true
  attr :chrome_visible, :any, required: true
  attr :default_terminal_sid, :any, required: true
  attr :desktop_terminal?, :any, required: true
  attr :desktop_terminal_pty, :any, required: true
  attr :desktop_terminal_refresh, :any, required: true
  attr :desktop_terminal_status, :any, required: true
  attr :desktop_terminal_term, :any, required: true
  attr :entered_preview_pane_id, :any, required: true
  attr :feature_panes, :any, required: true
  attr :file_pane_dirty, :any, required: true
  attr :focused_pane_id, :any, required: true
  attr :host_loc, :any, required: true
  attr :mobile_nav_focus, :any, required: true
  attr :mobile_nav_open, :any, required: true
  attr :mobile_nav_view, :any, required: true
  attr :pane_data, :any, required: true
  attr :pane_history, :any, required: true
  attr :preview_panes, :any, required: true
  attr :session_tabs, :any, required: true
  attr :sessions_sidebar_needs_you, :any, required: true
  attr :sessions_sidebar_open?, :any, required: true
  attr :sessions_sidebar_sort, :any, required: true
  attr :sessions_sidebar_tree, :any, required: true
  attr :shell_button_detail, :any, required: true
  attr :shell_button_label, :any, required: true
  attr :terminal_mode, :any, required: true
  attr :terminal_sid, :any, required: true
  attr :terminal_surface_pane_id, :any, required: true
  attr :terminal_themes, :any, required: true
  attr :tmux_active_pane_id, :any, required: true
  attr :tmux_mutations_enabled?, :any, required: true
  attr :tmux_rename_session_id, :any, required: true
  attr :tmux_rename_window_id, :any, required: true
  attr :tmux_session, :any, required: true
  attr :tmux_topology_layout_version, :any, required: true
  attr :tmux_topology_structure_version, :any, required: true
  attr :tmux_window_tabs, :any, required: true
  attr :tmux_windows, :any, required: true
  attr :ui_highlight_pane_id, :any, required: true
  attr :window_sidebar_open?, :any, required: true
  attr :window_zoomed?, :any, required: true
  attr :windows_sidebar_sort, :any, required: true
  attr :windows_sidebar_tree, :any, required: true
  attr :workspace, :any, required: true
  attr :workspace_route, :any, required: true
  attr :workspace_start_error, :any, required: true
  attr :agent_approval_count, :any, required: true

  def terminal_tab(assigns) do
    assigns =
      assign_new(assigns, :tmux_topology_layout_version, fn ->
        assigns[:tmux_topology_version] || 0
      end)

    ~H"""
    <section class="terminal-shell -mx-4 flex h-full min-h-0 flex-col lg:-mx-6">
      <div class="flex h-full min-h-0 flex-col overflow-hidden">
        <button
          :if={@agent_approval_count > 0}
          id={"agent-terminal-approval-banner-" <> @workspace.id}
          type="button"
          phx-click="notifications:toggle"
          class="group flex shrink-0 items-center gap-2 border-b border-status-warning/25 bg-status-warning/[0.08] px-3 py-2 text-left text-density-body text-status-warning-fg transition hover:bg-status-warning/[0.14] text-status-warning-fg"
        >
          <span class="relative flex size-2 shrink-0">
            <span class="absolute inline-flex size-full animate-ping rounded-full bg-status-warning opacity-50"></span>
            <span class="relative inline-flex size-2 rounded-full bg-status-warning"></span>
          </span>
          <span class="font-semibold">
            {@agent_approval_count} agent approval{if @agent_approval_count == 1,
              do: "",
              else: "s"} waiting
          </span>
          <span class="text-status-warning-fg/70">Review in Notifications</span>
          <.icon
            name="hero-arrow-right"
            class="ml-auto size-3.5 transition-transform duration-motion-state ease-motion-state group-hover:translate-x-0.5"
          />
        </button>
        <%= case @host_loc do %>
          <% {:ok, _loc} -> %>
            <div class="relative flex min-h-0 flex-1 overflow-hidden">
              <%= if (@sessions_sidebar_open? and @sessions_sidebar_tree != []) or
                      (@window_sidebar_open? and @windows_sidebar_tree != []) do %>
                <%!-- Keep summoned pickers out of the terminal's flex sizing.
                     Changing the terminal viewport retriggers its fit observer and
                     tmux grid resize; an overlay leaves the grid untouched.

                     Both summoned rails share this one click-away scope: clicking
                     inside either rail is contained (so two-column mode survives a
                     click between them), while a click in the terminal or header
                     dismisses the whole picker via sidebar:close. --%>
                <div
                  id={"terminal-picker-overlay-" <> @workspace.id}
                  data-terminal-picker-overlay="true"
                  phx-click-away="sidebar:close"
                  class="max-sm:hidden absolute inset-y-0 left-0 z-20 flex max-w-full overflow-hidden shadow-2xl"
                >
                  <%= if @sessions_sidebar_open? and @sessions_sidebar_tree != [] do %>
                    <SessionBar.sessions_sidebar
                      workspace_id={@workspace.id}
                      tree={@sessions_sidebar_tree}
                      needs_you={@sessions_sidebar_needs_you}
                      sort_mode={@sessions_sidebar_sort}
                      active_id={@terminal_sid}
                      default_sid={@default_terminal_sid}
                      preview_panes={@preview_panes}
                      path_base={@workspace_route}
                      mutations_allowed?={@tmux_mutations_enabled?}
                      rename_session_id={@tmux_rename_session_id}
                      session_tabs={@session_tabs}
                      chrome_visible?={@chrome_visible}
                    />
                  <% end %>
                  <%= if @window_sidebar_open? and @windows_sidebar_tree != [] do %>
                    <SessionBar.window_sidebar
                      workspace_id={@workspace.id}
                      path_base={@workspace_route}
                      tree={@windows_sidebar_tree}
                      sort_mode={@windows_sidebar_sort}
                      terminal_sid={@terminal_sid}
                      topology_version={@tmux_topology_structure_version}
                      mutations_allowed?={@tmux_mutations_enabled?}
                      rename_window_id={@tmux_rename_window_id}
                    />
                  <% end %>
                </div>
              <% end %>
              <div
                id={"terminal-viewport-" <> @workspace.id}
                data-terminal-viewport="true"
                class="flex min-h-0 min-w-0 flex-1 flex-col overflow-hidden"
              >
                <%= if @desktop_terminal? do %>
                  <.desktop_terminal_surface
                    term={@desktop_terminal_term}
                    pty={@desktop_terminal_pty}
                    status={@desktop_terminal_status}
                    refresh={@desktop_terminal_refresh}
                    terminal_themes={@terminal_themes}
                  />
                <% else %>
                  <%= if (@terminal_mode in [:raw, :raw_ghostty] and tmux_pane_surface?(assigns)) or
                          (@terminal_mode not in [:raw, :raw_ghostty] and
                             tmux_multi_pane_geometry?(assigns)) do %>
                    <.tmux_pane_geometry
                      workspace={@workspace}
                      active_tmux_window_panes={active_tmux_window_panes(@tmux_windows)}
                      preview_panes={@preview_panes}
                      feature_panes={@feature_panes}
                      tmux_session={@tmux_session}
                      ui_highlight_pane_id={@ui_highlight_pane_id}
                      tmux_active_pane_id={@tmux_active_pane_id}
                      window_zoomed?={@window_zoomed?}
                      topology_layout_version={@tmux_topology_layout_version}
                      tmux_mutations_enabled?={@tmux_mutations_enabled?}
                      entered_preview_pane_id={@entered_preview_pane_id}
                      terminal_surface_pane_id={@terminal_surface_pane_id}
                      pane_history={@pane_history}
                      terminal_themes={@terminal_themes}
                      focused_pane_id={@focused_pane_id}
                      pane_data={@pane_data}
                      workspace_start_error={@workspace_start_error}
                      file_pane_dirty={@file_pane_dirty}
                    />
                  <% else %>
                    <div class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950">
                      <.raw_terminal_surface
                        workspace={@workspace}
                        workspace_start_error={@workspace_start_error}
                        focused_pane_id={@focused_pane_id}
                        pane_data={@pane_data}
                        terminal_themes={@terminal_themes}
                      />
                    </div>
                  <% end %>
                <% end %>
              </div>
            </div>
            <.mobile_key_bar {assigns} />
            <.mobile_nav_sheet {assigns} />
            <%!-- First-run gesture coach-marks. The hook decides (mobile + not
                 yet seen) whether to render an overlay; the element itself is
                 an inert mount point. --%>
            <div
              id={"gesture-coach-" <> @workspace.id}
              phx-hook="GestureCoach"
              class="hidden"
              aria-hidden="true"
            >
            </div>
            <%!-- Web Push registration mount. Inert unless VAPID keys are
                 configured (data-vapid-key empty) and the browser has already
                 granted notification permission; the hook subscribes and posts
                 the PushSubscription to /api/push/subscribe. --%>
            <div
              id={"web-push-" <> @workspace.id}
              phx-hook="WebPush"
              data-workspace-id={@workspace.id}
              data-vapid-key={Casein.Push.WebPush.public_key_b64()}
              class="hidden"
              aria-hidden="true"
            >
            </div>
          <% {:error, :missing_path} -> %>
            <p class="text-sm text-status-danger-fg">
              Workspace has no host path. The manager has not finished provisioning, or this is a remote workspace.
            </p>
          <% {:error, :outside_root} -> %>
            <p class="text-sm text-status-danger-fg">
              Refusing to open terminal: workspace path is outside the allowed roots ({inspect(
                Workspaces.allowed_roots()
              )}).
            </p>
        <% end %>
      </div>
    </section>
    """
  end

  attr :term, :any, default: nil
  attr :pty, :any, default: nil
  attr :status, :any, default: :connecting
  attr :refresh, :integer, default: 0
  attr :terminal_themes, :any, default: nil

  def desktop_terminal_surface(assigns) do
    ~H"""
    <div
      id="desktop-native-terminal-surface"
      class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950"
      data-status={desktop_status_label(@status)}
    >
      <%= if is_pid(@term) do %>
        <.live_component
          module={CaseinWeb.GhosttyTerminalComponent}
          id="desktop-workspace-powershell"
          term={@term}
          pty={@pty}
          fit={true}
          autofocus={true}
          refresh={@refresh}
          input_refresh_delay={75}
          force_full_refresh={true}
          terminal_themes={@terminal_themes}
          class="h-full w-full font-mono text-sm"
        />
      <% else %>
        <div class="flex h-full items-center justify-center text-xs text-zinc-500">
          <%= if @status == :connecting do %>
            <CaseinWeb.WorkspaceLive.Show.UI.async_wait
              id="desktop-terminal-starting"
              class="text-xs text-zinc-500"
            >
              Starting native PowerShell…
            </CaseinWeb.WorkspaceLive.Show.UI.async_wait>
          <% else %>
            {desktop_status_label(@status)}
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp desktop_status_label(:running), do: "Connected"
  defp desktop_status_label(:connecting), do: "Starting native PowerShell…"
  defp desktop_status_label({:exited, _reason}), do: "PowerShell exited"
  defp desktop_status_label({:error, _reason}), do: "PowerShell unavailable"

  def mobile_key_bar(assigns) do
    ~H"""
    <div
      id={"mobile-key-bar-" <> @workspace.id}
      phx-hook="MobileKeyBar"
      class="mobile-key-bar fixed inset-x-0 z-30 items-center gap-1 overflow-visible border-t border-zinc-700/90 bg-zinc-950/95 px-1.5 py-1 text-zinc-200 backdrop-blur-md supports-[backdrop-filter]:bg-zinc-950/88"
      style="bottom: var(--casein-mobile-keybar-bottom, 0px); padding-bottom: max(var(--casein-mobile-keybar-padding-bottom, 0.25rem), var(--casein-mobile-keybar-safe-area-bottom, env(safe-area-inset-bottom)));"
      role="toolbar"
      aria-label="Terminal keys"
    >
      <div
        id={"mobile-key-bar-scroll-" <> @workspace.id}
        class="flex min-w-0 flex-1 items-center gap-1 overflow-x-auto"
      >
        <button
          id={"mobile-key-bar-mode-" <> @workspace.id}
          type="button"
          phx-click="mobile_nav:toggle"
          class="mr-0.5 inline-flex min-h-[1.9rem] shrink-0 items-center gap-1 rounded-md border border-status-live/30 bg-status-live/10 px-2 text-zinc-100 transition active:opacity-80"
          title={"Switch session or window — " <> mobile_mode_chip_title(assigns)}
          aria-label={
            "Switch session or window. Active session: " <>
              mobile_active_session_label(assigns) <> ". " <> mobile_mode_chip_title(assigns)
          }
          aria-expanded={@mobile_nav_open}
        >
          <%!-- tmux's own window.pane address, not a session name: at chip width
               a worktree label truncates to "…hoc-2026…" — it says nothing, and
               the collapsed chrome strip above already carries the session and
               window names. The address is what you need to know where a
               keystroke is going (and what C-b arrows will move). --%>
          <span
            data-mobile-window-number
            class="inline-flex shrink-0 justify-center font-mono text-density-body font-semibold leading-none text-status-live-fg/90"
            aria-hidden="true"
          >
            {mobile_active_pane_address(assigns)}
          </span>
          <.icon name="hero-chevron-up" class="size-3 shrink-0 text-zinc-500" />
        </button>
        <%!-- Static modifier + navigation keys. phx-update="ignore" preserves ctrl/alt latch state. --%>
        <div
          id={"mobile-key-bar-keys-" <> @workspace.id}
          phx-update="ignore"
          class="contents"
        >
          <button
            type="button"
            data-leader-prefix-button="true"
            aria-pressed="false"
            aria-label="tmux prefix key (Ctrl + B)"
            title="tmux prefix — tap, then a key"
            class={[
              mobile_key_class(),
              "aria-pressed:border-status-warning aria-pressed:bg-status-warning/20 aria-pressed:text-status-warning-fg"
            ]}
          >
            C-b
          </button>
          <%!-- Arrow d-pad leads the row so ↑↓←→ are always reachable without
               scrolling the bar (the most-used keys for cursor/history/menu nav
               and the on-screen "send up" affordance). --%>
          <button
            type="button"
            data-keybar-key="ArrowLeft"
            class={mobile_key_class()}
            aria-label="Left"
          >
            ←
          </button>
          <button
            type="button"
            data-keybar-key="ArrowDown"
            class={mobile_key_class()}
            aria-label="Down"
          >
            ↓
          </button>
          <button
            type="button"
            data-keybar-key="ArrowUp"
            class={mobile_key_class()}
            aria-label="Up"
          >
            ↑
          </button>
          <button
            type="button"
            data-keybar-key="ArrowRight"
            class={mobile_key_class()}
            aria-label="Right"
          >
            →
          </button>
          <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
          <button type="button" data-keybar-key="Escape" class={mobile_key_class()}>esc</button>
          <button
            type="button"
            data-keybar-key="Paste"
            class={mobile_key_class()}
            aria-label="Paste from clipboard"
          >
            paste
          </button>
          <button type="button" data-keybar-key="Tab" class={mobile_key_class()}>tab</button>
          <button
            type="button"
            data-keybar-key="Control"
            data-mod-state="off"
            aria-pressed="false"
            class={mobile_mod_class()}
          >
            ctrl
          </button>
          <button
            type="button"
            data-keybar-key="Alt"
            data-mod-state="off"
            aria-pressed="false"
            class={mobile_mod_class()}
          >
            alt
          </button>
          <button type="button" data-keybar-key="CtrlC" class={mobile_key_class()}>^C</button>
          <button
            type="button"
            data-keybar-key="Select"
            class={mobile_key_class()}
            aria-label="Select and copy terminal text"
          >
            select
          </button>
          <%!-- Not a keybar key: opens the LiveView drawer of what agents have
               copied, so a refused clipboard write stays recoverable. --%>
          <button
            type="button"
            phx-click="clipboard:toggle"
            class={mobile_key_class()}
            aria-label="Recent copies from agents"
          >
            clip
          </button>
        </div>
        <%!-- LiveView-updated pane/window action buttons. Current-window actions
             lead; window prev/next trail since swiping already cycles focus. --%>
        <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
        <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
          <button
            type="button"
            phx-click="split_right"
            class={mobile_key_class()}
            aria-label="Split right"
            title="Split right"
          >
            <.split_icon direction={:right} class="size-4" />
          </button>
          <button
            type="button"
            phx-click="split_down"
            class={mobile_key_class()}
            aria-label="Split down"
            title="Split down"
          >
            <.split_icon direction={:down} class="size-4" />
          </button>
          <%!-- No tmux-zoom toggle on mobile: the CSS focus-rails layer already shows
               one pane full-screen per-browser, and toggling shared tmux zoom here
               bled into the desktop operator's window. Use "Next pane" to switch. --%>
          <%= if @active_window_pane_count > 1 do %>
            <% pane_count = @active_window_pane_count %>
            <button
              type="button"
              phx-click="pane:focus_next"
              class={mobile_key_class() <> " relative"}
              aria-label={"Next pane (#{pane_count} total)"}
              title="Next pane"
            >
              <.icon name="hero-arrow-path" class="size-4" />
              <span class="absolute -right-0.5 -top-0.5 flex size-3.5 items-center justify-center rounded-full bg-primary text-density-micro font-bold leading-none text-primary-content">
                {pane_count}
              </span>
            </button>
            <button
              type="button"
              phx-click="pane:close_focused"
              class={mobile_key_class()}
              aria-label="Close pane"
              title="Close pane"
            >
              ×
            </button>
          <% end %>
        <% end %>
        <%= if @tmux_mutations_enabled? do %>
          <button
            type="button"
            phx-click="tmux:new_window"
            data-keybar-secondary="true"
            class={mobile_key_class()}
            aria-label="New window"
            title="New window"
          >
            +
          </button>
        <% end %>
        <button
          type="button"
          data-keybar-key="Palette"
          class={mobile_key_class()}
          aria-label="Open command palette"
          title="Command palette"
        >
          ⌘
        </button>
        <%= if length(@tmux_window_tabs) > 1 do %>
          <button
            type="button"
            phx-click="tmux:cycle_window"
            phx-value-dir="prev"
            data-keybar-secondary="true"
            class={mobile_key_class()}
            aria-label="Previous window"
            title="Previous window"
          >
            ‹
          </button>
          <button
            type="button"
            phx-click="tmux:last_window"
            data-keybar-secondary="true"
            class={mobile_key_class()}
            aria-label="Last window"
            title="Last window"
          >
            <.icon name="hero-clock" class="size-4" />
          </button>
          <button
            type="button"
            phx-click="tmux:cycle_window"
            phx-value-dir="next"
            data-keybar-secondary="true"
            class={mobile_key_class()}
            aria-label="Next window"
            title="Next window"
          >
            ›
          </button>
        <% end %>
        <span
          data-keybar-secondary="true"
          class="mx-0.5 h-5 w-px flex-none bg-zinc-700"
        ></span>
        <button
          type="button"
          data-keybar-key="FontDown"
          class={mobile_key_class()}
          aria-label="Decrease font size"
          title="Decrease font size"
        >
          A-
        </button>
        <button
          type="button"
          data-keybar-key="FontUp"
          class={mobile_key_class()}
          aria-label="Increase font size"
          title="Increase font size"
        >
          A+
        </button>
        <span
          data-keybar-secondary="true"
          class="mx-0.5 h-5 w-px flex-none bg-zinc-700"
        ></span>
        <button
          type="button"
          data-keybar-key="ZoomDown"
          class={mobile_key_class()}
          aria-label="Decrease display zoom"
          title="Decrease display zoom"
        >
          −
        </button>
        <button
          type="button"
          data-keybar-key="ZoomReset"
          class={mobile_key_class()}
          aria-label="Reset display zoom"
          title="Reset display zoom"
        >
          1×
        </button>
        <button
          type="button"
          data-keybar-key="ZoomUp"
          class={mobile_key_class()}
          aria-label="Increase display zoom"
          title="Increase display zoom"
        >
          +
        </button>
      </div>
    </div>
    """
  end

  def mobile_nav_sheet(assigns) do
    # Window-picker-dominant: the sheet opens on the attached session's window
    # list; a back arrow (or ← on a window row) hops out to the sessions tree.
    # Resolve the view at render time so a session losing its windows while the
    # sheet is open degrades to the sessions list instead of an empty pane.
    active_tab = mobile_nav_active_tab(assigns)

    view =
      if assigns.mobile_nav_view == "windows" and match?(%{windows: [_ | _]}, active_tab),
        do: "windows",
        else: "sessions"

    assigns =
      assigns
      |> Phoenix.Component.assign(:mnav_active_tab, active_tab)
      |> Phoenix.Component.assign(:mnav_view, view)
      |> Phoenix.Component.assign(:mnav_other_nodes, mobile_other_workspace_nodes(assigns))

    ~H"""
    <div
      :if={@mobile_nav_open}
      id={"mobile-nav-sheet-" <> @workspace.id}
      phx-hook="MobileNavSheet"
      data-mobile-nav-focus={@mobile_nav_focus}
      data-mobile-nav-view={@mnav_view}
      data-mobile-nav-sheet="true"
      class="mobile-nav-sheet fixed inset-0 z-40 hidden"
      role="dialog"
      aria-modal="true"
      aria-label="Session and window picker"
    >
      <button
        type="button"
        phx-click="mobile_nav:close"
        class="absolute inset-0 bg-black/45"
        aria-label="Close session and window picker"
      ></button>
      <div
        class="absolute inset-x-0 bottom-0 max-h-[70dvh] overflow-y-auto rounded-t-xl border border-zinc-700 bg-zinc-950 px-3 pb-3 pt-3 text-zinc-100 shadow-2xl"
        style="margin-bottom: var(--casein-mobile-terminal-inset, 0px);"
      >
        <div class="mb-2 flex items-center justify-between gap-2">
          <div class="flex min-w-0 items-center gap-1.5">
            <button
              :if={@mnav_view == "windows"}
              type="button"
              phx-click="mobile_nav:set_view"
              phx-value-view="sessions"
              class="flex shrink-0 items-center justify-center rounded border border-zinc-700 p-1 text-zinc-300 hover:bg-zinc-800 hover:text-zinc-100"
              aria-label="Back to all sessions"
              title="All sessions"
            >
              <.icon name="hero-chevron-left" class="size-4" />
            </button>
            <div class="min-w-0">
              <div class="text-density-label font-semibold uppercase tracking-wide text-zinc-500">
                {if @mnav_view == "windows", do: "Windows", else: "Navigate"}
              </div>
              <div class="truncate text-sm font-medium">{mobile_nav_sheet_title(assigns)}</div>
            </div>
          </div>
          <button
            type="button"
            phx-click="mobile_nav:close"
            class="shrink-0 rounded border border-zinc-700 px-2 py-0.5 text-xs text-zinc-300"
          >
            Done
          </button>
        </div>
        <%!-- Dominant view: flat window list of the attached session. --%>
        <div :if={@mnav_view == "windows"} class="space-y-0.5">
          <%= for window <- mobile_sorted_windows(@mnav_active_tab.windows, assigns) do %>
            <div class="flex items-center gap-1">
              <button
                type="button"
                data-picker-item
                data-picker-section="windows"
                data-picker-active={window.active? || nil}
                phx-click={
                  JS.push("tmux:select_window", value: %{"window-id" => window.id})
                  |> JS.push("mobile_nav:close")
                }
                class={[
                  mobile_nav_row_class(window.active?),
                  "min-w-0 flex-1 flex-row items-center gap-1.5"
                ]}
              >
                <span class="font-mono text-density-label text-zinc-500">{window.index}</span>
                <span data-picker-label class="min-w-0 truncate font-medium">{window.name}</span>
              </button>
              <SessionBar.copy_link_button
                url={
                  SessionBar.share_url(@workspace.id, @mnav_active_tab.id, window.id,
                    path_base: @workspace_route
                  )
                }
                label={@mnav_active_tab.label <> " · " <> window.name}
                kind="window"
                visible?={true}
              />
            </div>
          <% end %>
        </div>
        <%!--
          Tree picker: sessions are top-level rows, their tmux windows nest
          beneath (mirrors the desktop SessionBar.session_dropdown tree). Rows
          carry [data-picker-item]/[data-picker-active] and the windows-group
          wiring (data-picker-windows-id / data-picker-parent) that the
          MobileNavSheet hook drives with ↑/↓/→/←/Enter/Esc. Ids are prefixed
          "mnav-" so they never collide with the (also-rendered, CSS-hidden)
          desktop dropdown's ids.
        --%>
        <div
          :if={@mnav_view == "sessions"}
          class="mb-1 flex items-center gap-1.5 text-density-label font-semibold uppercase tracking-wide text-zinc-500"
        >
          <.icon name="hero-folder" class="size-3 shrink-0" />
          <span class="min-w-0 truncate normal-case text-zinc-300">
            {@workspace.name || @workspace.id}
          </span>
          <span class="lowercase text-zinc-600">· this workspace</span>
        </div>
        <div :if={@mnav_view == "sessions"} class="space-y-0.5">
          <div :if={@session_tabs == []} class="flex items-center gap-1">
            <button
              type="button"
              data-picker-item
              data-picker-section="sessions"
              data-picker-active={true}
              phx-click={
                JS.push("terminal:switch_to_shell")
                |> JS.push("mobile_nav:close")
              }
              class={[mobile_nav_row_class(true), "min-w-0 flex-1"]}
            >
              <span class="flex min-w-0 items-center gap-1">
                <.icon name="hero-home" class="size-3 shrink-0 text-zinc-500" />
                <span data-picker-label class="truncate font-medium">
                  {@shell_button_label}
                </span>
              </span>
              <span
                :if={@shell_button_detail != ""}
                class="truncate font-mono text-density-label text-zinc-500"
              >
                {@shell_button_detail}
              </span>
            </button>
            <SessionBar.copy_link_button
              url={
                SessionBar.share_url(@workspace.id, @default_terminal_sid, nil,
                  path_base: @workspace_route
                )
              }
              label={@shell_button_label}
              visible?={true}
            />
          </div>
          <%= for tab <- @session_tabs do %>
            <% session_active? = @terminal_sid == tab.id %>
            <div class="flex items-center gap-1">
              <button
                type="button"
                data-picker-item
                data-picker-section="sessions"
                data-picker-active={session_active? || nil}
                data-picker-windows-id={tab.window_count > 0 && tab.dom_id}
                phx-click={
                  JS.push("attach_terminal_session",
                    value: %{
                      "session-id" => tab.id,
                      "kind" => Atom.to_string(tab.kind),
                      "tmux-session" => tab.tmux_session
                    }
                  )
                  |> JS.push("mobile_nav:close")
                }
                class={[
                  mobile_nav_row_class(session_active?),
                  "min-w-0 flex-1 flex-row items-center gap-1.5"
                ]}
              >
                <.icon
                  :if={tab.id == @default_terminal_sid}
                  name="hero-home"
                  class="size-3 shrink-0 text-zinc-500"
                />
                <span data-picker-label class="min-w-0 truncate font-medium">{tab.label}</span>
                <.mnav_session_anchor tab={tab} />
                <span
                  :if={tab.detail_secondary != ""}
                  class="ml-auto max-w-[38%] shrink-0 truncate font-mono text-density-label text-zinc-500"
                >
                  {tab.detail_secondary}
                </span>
              </button>
              <button
                :if={tab.window_count > 0}
                id={"mnav-windows-toggle-" <> tab.dom_id}
                type="button"
                tabindex="-1"
                phx-click={
                  JS.toggle(to: "#mnav-windows-" <> tab.dom_id, display: "block")
                  |> JS.toggle_class("rotate-90", to: "#mnav-windows-chevron-" <> tab.dom_id)
                }
                class="flex shrink-0 items-center gap-density-label rounded px-1.5 py-1 font-mono text-density-label text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200"
                aria-label={"Toggle windows of " <> tab.label}
              >
                {tab.window_count}
                <span
                  id={"mnav-windows-chevron-" <> tab.dom_id}
                  class={[
                    "flex transition-transform duration-motion-state ease-motion-state",
                    session_active? && "rotate-90"
                  ]}
                >
                  <.icon name="hero-chevron-right" class="size-3" />
                </span>
              </button>
              <SessionBar.copy_link_button
                url={SessionBar.share_url(@workspace.id, tab.id, nil, path_base: @workspace_route)}
                label={tab.label}
                visible?={true}
              />
            </div>
            <div
              :if={tab.windows != []}
              id={"mnav-windows-" <> tab.dom_id}
              class={["space-y-0.5 pl-3", !session_active? && "hidden"]}
            >
              <%= for window <- mobile_sorted_windows(tab.windows, assigns) do %>
                <div class="flex items-center gap-1">
                  <button
                    type="button"
                    data-picker-item
                    data-picker-section="windows"
                    data-picker-parent={tab.dom_id}
                    data-picker-active={(session_active? and window.active?) || nil}
                    phx-click={
                      # Active session: a cheap in-session window switch. Other
                      # sessions: attach to that session on the chosen window.
                      if session_active? do
                        JS.push("tmux:select_window", value: %{"window-id" => window.id})
                        |> JS.push("mobile_nav:close")
                      else
                        JS.push("attach_terminal_session",
                          value: %{
                            "session-id" => tab.id,
                            "kind" => Atom.to_string(tab.kind),
                            "tmux-session" => tab.tmux_session,
                            "window-id" => window.id
                          }
                        )
                        |> JS.push("mobile_nav:close")
                      end
                    }
                    class={[
                      mobile_nav_row_class(session_active? and window.active?),
                      "min-w-0 flex-1 flex-row items-center gap-1.5"
                    ]}
                  >
                    <span class="font-mono text-density-label text-zinc-500">{window.index}</span>
                    <span data-picker-label class="min-w-0 truncate font-medium">{window.name}</span>
                  </button>
                  <SessionBar.copy_link_button
                    url={
                      SessionBar.share_url(@workspace.id, tab.id, window.id,
                        path_base: @workspace_route
                      )
                    }
                    label={tab.label <> " · " <> window.name}
                    kind="window"
                    visible?={true}
                  />
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
        <%!--
          Cross-workspace reach: the desktop rail's "Other workspaces" half,
          brought to the mobile sheet. Nodes come from @sessions_sidebar_tree
          (built as the sheet opens); tapping a collapsed workspace fires the
          shared `sidebar:toggle_workspace` (lazy-loads its sessions), and a
          session row navigates into that workspace.
        --%>
        <div
          :if={@mnav_view == "sessions" and @mnav_other_nodes != []}
          class="mb-1 mt-3 flex items-center gap-1.5 border-t border-zinc-800 pt-2 text-density-label font-semibold uppercase tracking-wide text-zinc-500"
        >
          <.icon name="hero-squares-2x2" class="size-3 shrink-0" /> Other workspaces
        </div>
        <div :if={@mnav_view == "sessions" and @mnav_other_nodes != []} class="space-y-0.5">
          <.mobile_other_workspace_node
            :for={node <- @mnav_other_nodes}
            node={node}
            workspace_route={@workspace_route}
          />
        </div>
      </div>
    </div>
    """
  end

  # One "Other workspaces" row in the mobile sheet. Mirrors the desktop
  # `SessionBar.sessions_sidebar_node` :other branch: a flat single-session row,
  # or an expandable workspace whose session children navigate cross-workspace.
  attr :node, :map, required: true
  attr :workspace_route, :string, default: nil

  defp mobile_other_workspace_node(assigns) do
    ~H"""
    <%= cond do %>
      <% @node.flat_session? -> %>
        <.link
          navigate={SessionBar.cross_workspace_session_path(@node.workspace_id, @node.session)}
          data-picker-item
          data-picker-section="sessions"
          class={[mobile_nav_row_class(false), "min-w-0", not @node.live? && "opacity-60"]}
          title={@node.title}
        >
          <span data-picker-label class="truncate font-medium">{@node.label}</span>
        </.link>
      <% is_list(@node.sessions) -> %>
        <div class="flex flex-col gap-0.5">
          <button
            type="button"
            data-picker-item
            data-picker-section="workspaces"
            phx-click="sidebar:toggle_workspace"
            phx-value-workspace-id={@node.workspace_id}
            class={[
              mobile_nav_row_class(false),
              "min-w-0 flex-row items-center gap-2",
              not @node.live? && "opacity-60"
            ]}
            title={@node.title}
            aria-label={
              if(@node.expanded?, do: "Collapse " <> @node.label, else: "Expand " <> @node.label)
            }
          >
            <span class="min-w-0 flex-1 truncate text-left font-medium">{@node.label}</span>
            <span class="flex shrink-0 items-center gap-density-label font-mono text-density-label text-zinc-500">
              {@node.session_count}
              <span class={[
                "flex transition-transform duration-motion-state ease-motion-state",
                @node.expanded? && "rotate-90"
              ]}>
                <.icon name="hero-chevron-right" class="size-3" />
              </span>
            </span>
          </button>
          <div class="space-y-0.5 pl-3">
            <%= for session <- @node.sessions do %>
              <.link
                navigate={SessionBar.cross_workspace_session_path(@node.workspace_id, session)}
                data-picker-item
                data-picker-section="sessions"
                class={[mobile_nav_row_class(false), "min-w-0"]}
                title={session.title}
              >
                <span data-picker-label class="truncate font-medium">{session.label}</span>
              </.link>
            <% end %>
          </div>
        </div>
      <% Map.get(@node, :openable?, true) -> %>
        <%!-- Sessions not lazy-loaded yet. Tapping the row navigates to the
             workspace root (its mount picks the landing session) — same target
             as the desktop sidebar's unresolved-home row; expansion moves to
             the dedicated count/chevron button. --%>
        <div class="flex items-stretch gap-0.5">
          <.link
            navigate={SessionBar.cross_workspace_home_path(@node.workspace_id)}
            data-picker-item
            data-picker-section="workspaces"
            class={[
              mobile_nav_row_class(false),
              "min-w-0 flex-1 flex-row items-center gap-2",
              not @node.live? && "opacity-60"
            ]}
            title={@node.title}
          >
            <span class="min-w-0 flex-1 truncate text-left font-medium">{@node.label}</span>
          </.link>
          <button
            :if={@node.session_count > 0}
            type="button"
            phx-click="sidebar:toggle_workspace"
            phx-value-workspace-id={@node.workspace_id}
            class="flex shrink-0 items-center gap-density-label rounded px-1.5 font-mono text-density-label text-zinc-500"
            aria-label={"Expand " <> @node.label}
          >
            {@node.session_count}
            <span class="flex"><.icon name="hero-chevron-right" class="size-3" /></span>
          </button>
        </div>
      <% true -> %>
        <%!-- Teammate workspace (openable?: false): keep the legacy
             non-navigable expand/collapse toggle. --%>
        <button
          type="button"
          data-picker-item
          data-picker-section="workspaces"
          phx-click="sidebar:toggle_workspace"
          phx-value-workspace-id={@node.workspace_id}
          class={[
            mobile_nav_row_class(false),
            "min-w-0 flex-row items-center gap-2",
            not @node.live? && "opacity-60"
          ]}
          title={@node.title}
          aria-label={"Expand " <> @node.label}
        >
          <span class="min-w-0 flex-1 truncate text-left font-medium">{@node.label}</span>
          <span
            :if={@node.session_count > 0}
            class="flex shrink-0 items-center gap-density-label font-mono text-density-label text-zinc-500"
          >
            {@node.session_count}
            <span class="flex"><.icon name="hero-chevron-right" class="size-3" /></span>
          </span>
        </button>
    <% end %>
    """
  end

  # Workspace-tier nodes (skip the Browse tier) from the sessions tree that
  # belong to OTHER workspaces — the half the mobile sheet previously dropped.
  defp mobile_other_workspace_nodes(assigns) do
    assigns
    |> Map.get(:sessions_sidebar_tree, [])
    |> Enum.filter(fn node ->
      Map.get(node, :kind) not in [:browse_root, :browse_dir] and
        Map.get(node, :group, :other) == :other
    end)
  end

  # Repo/branch anchor chip for a mobile session row — interesting-only (a
  # worktree or a non-default branch) via the shared SessionBar predicate, so
  # plain master/main stays out of the way. For a worktree it reads
  # "repo⑂branch", surfacing the repo a worktree cwd otherwise hides.
  attr :tab, :map, required: true

  defp mnav_session_anchor(assigns) do
    ~H"""
    <span
      :if={SessionBar.session_anchor_interesting?(@tab)}
      class="inline-flex min-w-0 shrink items-center gap-density-badge rounded bg-zinc-800 px-1 font-mono text-density-badge text-zinc-400"
      title={mnav_anchor_title(@tab)}
    >
      <.icon name="hero-arrows-right-left" class="size-2.5 shrink-0" /><span
        :if={Map.get(@tab, :worktree?) and Map.get(@tab, :repo, "") != ""}
        class="shrink-0 text-zinc-500"
      >{@tab.repo}⑂</span><span class="max-w-28 truncate">{SessionBar.branch_short(@tab.branch)}</span>
    </span>
    """
  end

  defp mnav_anchor_title(%{worktree?: true, repo: repo, branch: branch})
       when is_binary(repo) and repo != "" do
    "Worktree of " <> repo <> " · branch " <> branch
  end

  defp mnav_anchor_title(%{branch: branch}) when is_binary(branch), do: "Branch " <> branch
  defp mnav_anchor_title(_), do: nil

  defp mobile_nav_row_class(true),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded border border-primary/40 bg-primary/10 px-2.5 py-1.5 text-left text-xs text-primary"

  defp mobile_nav_row_class(false),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded px-2.5 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800"

  defp mobile_key_class do
    "inline-flex flex-none items-center justify-center rounded border border-zinc-700 bg-zinc-800 " <>
      "px-2.5 font-mono text-xs leading-none active:bg-zinc-700 hover:bg-zinc-700 transition-colors duration-motion-state ease-motion-state " <>
      "min-w-[2.25rem] min-h-[1.9rem]"
  end

  # Sticky-modifier styling driven by the data-mod-state the JS hook maintains
  # (off | armed | locked). Arbitrary variants key off the data attribute so the
  # JS only has to flip one attribute, no class juggling.
  defp mobile_mod_class do
    "inline-flex flex-none items-center justify-center rounded border px-2.5 font-mono text-xs leading-none " <>
      "transition-colors duration-motion-state ease-motion-state min-w-[2.5rem] min-h-[1.9rem] " <>
      "border-zinc-700 bg-zinc-800 " <>
      "data-[mod-state=armed]:border-status-ok data-[mod-state=armed]:bg-status-ok/20 data-[mod-state=armed]:text-status-ok-fg" <>
      "data-[mod-state=locked]:border-status-warning data-[mod-state=locked]:bg-status-warning/30 data-[mod-state=locked]:text-status-warning-fg"
  end

  defp active_tmux_window_name(assigns) do
    CaseinWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{assigns: assigns})
  end

  # Read the active window off the topology's own `active` flag rather than
  # matching :tmux_active_window_id — that assign is never threaded this far
  # (see terminal_tab_attrs), so the id lookup always missed and the chip has
  # been rendering its "–" fallback on every phone.
  defp mobile_active_window_index(assigns) do
    case Enum.find(assigns[:tmux_windows] || [], &Map.get(&1, :active)) do
      %{index: index} when is_integer(index) -> Integer.to_string(index)
      _ -> "–"
    end
  end

  # tmux's `window.pane` address for the pane the soft keyboard is typing into —
  # UI focus first, since tapping a tile highlights it before tmux agrees. Falls
  # back to the bare window number when no pane resolves (topology still
  # arriving), so the chip never goes empty.
  defp mobile_active_pane_address(assigns) do
    window = mobile_active_window_index(assigns)
    panes = active_tmux_window_panes(assigns[:tmux_windows] || [])
    highlighted = assigns[:ui_highlight_pane_id]

    pane =
      Enum.find(panes, &(is_binary(highlighted) and Map.get(&1, :id) == highlighted)) ||
        Enum.find(panes, &Map.get(&1, :active))

    case pane do
      %{index: index} when is_integer(index) -> window <> "." <> Integer.to_string(index)
      _ -> window
    end
  end

  defp mobile_sorted_windows(windows, assigns) do
    SessionBarVM.sort_window_tree(windows, assigns[:windows_sidebar_sort] || :recency)
  end

  # Name of the currently attached session, used to label the mobile session
  # chip so it reads as a session switcher rather than a bare mode badge.
  # Long worktree / path labels are shortened for the narrow key bar chip.
  defp mobile_active_session_label(assigns) do
    raw =
      if assigns.terminal_sid == assigns.default_terminal_sid do
        case assigns.shell_button_label do
          label when is_binary(label) and label != "" -> label
          _ -> "Shell"
        end
      else
        case Enum.find(assigns.session_tabs, &(&1.id == assigns.terminal_sid)) do
          %{label: label} when is_binary(label) and label != "" -> label
          _ -> "Session"
        end
      end

    mobile_short_session_label(raw)
  end

  # Prefer a readable tail for long worktree/agent labels
  # ("casein-agent-worktrees/foo" → "…/foo", "agent/grok/adhoc-…" → last segment).
  defp mobile_short_session_label(label) when is_binary(label) do
    trimmed = String.trim(label)

    cond do
      String.length(trimmed) <= 22 ->
        trimmed

      String.contains?(trimmed, "/") ->
        trimmed
        |> String.split("/", trim: true)
        |> List.last()
        |> case do
          nil -> trimmed
          last when byte_size(last) > 22 -> "…" <> String.slice(last, -18, 18)
          last -> last
        end

      true ->
        "…" <> String.slice(trimmed, -18, 18)
    end
  end

  defp mobile_mode_chip_title(assigns) do
    case active_tmux_window_name(assigns) do
      name when is_binary(name) and name != "" -> "Window \"#{name}\""
      _ -> "Terminal session"
    end
  end

  defp mobile_nav_sheet_title(%{mnav_view: "windows"} = assigns),
    do: mobile_active_session_label(assigns)

  defp mobile_nav_sheet_title(_assigns), do: "All sessions"

  # The session tab the terminal is currently attached to, if any — nil while
  # on the default shell (no tmux) or before session tabs load.
  defp mobile_nav_active_tab(assigns) do
    Enum.find(assigns[:session_tabs] || [], &(&1.id == assigns[:terminal_sid]))
  end

  # "windows" only makes sense when the attached session actually has tmux
  # windows to list; everything else lands on the sessions tree.
end
