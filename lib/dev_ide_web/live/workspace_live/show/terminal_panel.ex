defmodule DevIdeWeb.WorkspaceLive.Show.TerminalPanel do
  @moduledoc false

  use DevIdeWeb, :html
  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  alias DevIDE.Workspaces
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar

  def terminal_tab(assigns) do
    ~H"""
    <section class="terminal-shell -mx-4 flex h-full min-h-0 flex-col lg:-mx-6">
      <div class="flex h-full min-h-0 flex-col overflow-hidden">
        <%= case @host_loc do %>
          <% {:ok, _loc} -> %>
            <div class="flex min-h-0 flex-1 flex-col overflow-hidden">
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
                  tmux_mutations_enabled?={@tmux_mutations_enabled?}
                  entered_preview_pane_id={@entered_preview_pane_id}
                  terminal_surface_pane_id={@terminal_surface_pane_id}
                  pane_history={@pane_history}
                  terminal_themes={@terminal_themes}
                  focused_pane_id={@focused_pane_id}
                  pane_data={@pane_data}
                  workspace_start_error={@workspace_start_error}
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
            </div>
            <.mobile_key_bar {assigns} />
            <.mobile_nav_sheet {assigns} />
          <% {:error, :missing_path} -> %>
            <p class="text-sm text-red-700">
              Workspace has no host path. The manager has not finished provisioning, or this is a remote workspace.
            </p>
          <% {:error, :outside_root} -> %>
            <p class="text-sm text-red-700">
              Refusing to open terminal: workspace path is outside the allowed roots ({inspect(
                Workspaces.allowed_roots()
              )}).
            </p>
        <% end %>
      </div>
    </section>
    """
  end

  def mobile_key_bar(assigns) do
    ~H"""
    <div
      id={"mobile-key-bar-" <> @workspace.id}
      phx-hook="MobileKeyBar"
      class="mobile-key-bar fixed inset-x-0 z-30 items-center gap-1 overflow-visible border-t border-zinc-700 bg-zinc-900/95 px-1.5 py-1 text-zinc-200 backdrop-blur supports-[backdrop-filter]:bg-zinc-900/80"
      style="bottom: var(--devide-mobile-keybar-bottom, 0px); padding-bottom: max(var(--devide-mobile-keybar-padding-bottom, 0.25rem), var(--devide-mobile-keybar-safe-area-bottom, env(safe-area-inset-bottom)));"
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
          class="mr-0.5 inline-flex min-h-[1.9rem] shrink-0 items-center gap-1 rounded border border-zinc-600 bg-zinc-800 px-1.5 text-zinc-100 transition active:opacity-80"
          title={"Switch session or window — " <> mobile_mode_chip_title(assigns)}
          aria-label={
            "Switch session or window. Active session: " <>
              mobile_active_session_label(assigns) <> ". " <> mobile_mode_chip_title(assigns)
          }
          aria-expanded={@mobile_nav_open}
        >
          <.icon name="hero-rectangle-stack" class="size-3.5 shrink-0 text-zinc-400" />
          <span class="max-w-[6.5rem] truncate text-[11px] font-medium leading-none">
            {mobile_active_session_label(assigns)}
          </span>
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
              "aria-pressed:border-amber-400 aria-pressed:bg-amber-500/20 aria-pressed:text-amber-300"
            ]}
          >
            C-b
          </button>
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
          <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
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
              <span class="absolute -right-0.5 -top-0.5 flex size-3.5 items-center justify-center rounded-full bg-primary text-[8px] font-bold leading-none text-primary-content">
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
            class={mobile_key_class()}
            aria-label="Previous window"
            title="Previous window"
          >
            ‹
          </button>
          <button
            type="button"
            phx-click="tmux:last_window"
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
            class={mobile_key_class()}
            aria-label="Next window"
            title="Next window"
          >
            ›
          </button>
        <% end %>
        <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
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
        <span class="mx-0.5 h-5 w-px flex-none bg-zinc-700"></span>
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

    ~H"""
    <div
      :if={@mobile_nav_open}
      id={"mobile-nav-sheet-" <> @workspace.id}
      phx-hook="MobileNavSheet"
      data-mobile-nav-focus={@mobile_nav_focus}
      data-mobile-nav-view={@mnav_view}
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
        style="margin-bottom: var(--devide-mobile-terminal-inset, 0px);"
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
              <div class="text-[10px] font-semibold uppercase tracking-wide text-zinc-500">
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
          <%= for window <- @mnav_active_tab.windows do %>
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
                <span class="font-mono text-[10px] text-zinc-500">{window.index}</span>
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
          class="mb-1 text-[10px] font-semibold uppercase tracking-wide text-zinc-500"
        >
          Sessions &amp; windows
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
                class="truncate font-mono text-[10px] text-zinc-500"
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
                class={[mobile_nav_row_class(session_active?), "min-w-0 flex-1"]}
              >
                <span class="flex min-w-0 items-center gap-1">
                  <.icon
                    :if={tab.id == @default_terminal_sid}
                    name="hero-home"
                    class="size-3 shrink-0 text-zinc-500"
                  />
                  <span data-picker-label class="truncate font-medium">{tab.label}</span>
                </span>
                <span :if={tab.detail != ""} class="truncate font-mono text-[10px] text-zinc-500">
                  {tab.detail}
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
                class="flex shrink-0 items-center gap-0.5 rounded px-1.5 py-1 font-mono text-[10px] text-zinc-400 hover:bg-zinc-800 hover:text-zinc-200"
                aria-label={"Toggle windows of " <> tab.label}
              >
                {tab.window_count}
                <span
                  id={"mnav-windows-chevron-" <> tab.dom_id}
                  class={[
                    "flex transition-transform",
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
              <%= for window <- tab.windows do %>
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
                    <span class="font-mono text-[10px] text-zinc-500">{window.index}</span>
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
      </div>
    </div>
    """
  end

  defp mobile_nav_row_class(true),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded border border-primary/40 bg-primary/10 px-2.5 py-1.5 text-left text-xs text-primary"

  defp mobile_nav_row_class(false),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded px-2.5 py-1.5 text-left text-xs text-zinc-300 hover:bg-zinc-800"

  defp mobile_key_class do
    "inline-flex flex-none items-center justify-center rounded border border-zinc-700 bg-zinc-800 " <>
      "px-2.5 font-mono text-xs leading-none active:bg-zinc-700 hover:bg-zinc-700 transition-colors " <>
      "min-w-[2.25rem] min-h-[1.9rem]"
  end

  # Sticky-modifier styling driven by the data-mod-state the JS hook maintains
  # (off | armed | locked). Arbitrary variants key off the data attribute so the
  # JS only has to flip one attribute, no class juggling.
  defp mobile_mod_class do
    "inline-flex flex-none items-center justify-center rounded border px-2.5 font-mono text-xs leading-none " <>
      "transition-colors min-w-[2.5rem] min-h-[1.9rem] " <>
      "border-zinc-700 bg-zinc-800 " <>
      "data-[mod-state=armed]:border-emerald-400 data-[mod-state=armed]:bg-emerald-500/20 data-[mod-state=armed]:text-emerald-300 " <>
      "data-[mod-state=locked]:border-amber-400 data-[mod-state=locked]:bg-amber-500/30 data-[mod-state=locked]:text-amber-200"
  end

  defp active_tmux_window_name(assigns) do
    DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{assigns: assigns})
  end

  # Name of the currently attached session, used to label the mobile session
  # chip so it reads as a session switcher rather than a bare mode badge.
  defp mobile_active_session_label(assigns) do
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
