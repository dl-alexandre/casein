defmodule CaseinWeb.WorkspaceLive.Show.WorkspaceShell do
  @moduledoc """
  Workspace chrome shell markup.

  ## Responsive rule (issue #735)

  `pointer-coarse` decides hit targets, spacing, and gesture affordances;
  width decides layout and information density. See
  `docs/subsystems/web_cockpit.md`. Do not hide pickers or swap nav models
  with `pointer-coarse:` alone — use `max-sm:` / width media / `data-chrome-narrow`.
  """

  use CaseinWeb, :html

  import CaseinWeb.WorkspaceLive.Show.UI
  import CaseinWeb.WorkspaceLive.Show.TerminalChrome
  import CaseinWeb.WorkspaceLive.Show.RunPanel
  import CaseinWeb.WorkspaceLive.Show.SidePanels
  import CaseinWeb.WorkspaceLive.Show.TemplatePanels
  import CaseinWeb.WorkspaceLive.Show.LogsPanel
  import CaseinWeb.WorkspaceLive.Show.HistoryPanel

  import CaseinWeb.WorkspaceLive.Show.WorkspaceHeader,
    only: [
      header_overflow_menu: 1,
      workspace_start_blocked?: 1,
      workspace_status_dot_class: 1,
      header_status_action: 2,
      header_status_action_label: 2
    ]

  import CaseinWeb.WorkspaceLive.Show.TerminalPanel, only: [terminal_tab: 1]

  import CaseinWeb.WorkspaceLive.Show.SituationPanel,
    only: [situation_badge: 1, situation_drawer: 1]

  import CaseinWeb.WorkspaceLive.Show.PalettePanel, only: [palette_overlay: 1]
  import CaseinWeb.WorkspaceLive.Show.LeaderHelp, only: [leader_help_overlay: 1]
  import CaseinWeb.WorkspaceLive.Show.AgentWriteBanner, only: [agent_write_locked_banner: 1]

  alias Casein.Cockpit.Geometry
  alias CaseinWeb.NotificationsDrawer
  alias CaseinWeb.WorkspaceLive.Show.ActionAvailability
  alias CaseinWeb.WorkspaceLive.Show.ClipboardDrawer
  alias CaseinWeb.WorkspaceLive.Show.ContextMenu
  alias CaseinWeb.WorkspaceLive.Show.LeaderBindings
  alias CaseinWeb.WorkspaceLive.Show.SessionBar

  attr :active_run, :any, required: true
  attr :active_session_kind, :any, required: true
  attr :active_window_pane_count, :any, required: true
  attr :agent_pending_approval_count, :any, required: true
  attr :agent_write_unlock, :any, required: true
  attr :artifact_projects, :any, required: true
  attr :artifact_projects_error, :any, required: true
  attr :artifact_selected_id, :any, required: true
  attr :audit_drawer_open, :any, required: true
  attr :chrome_visible, :any, required: true
  attr :clipboard_count, :any, required: true
  attr :clipboard_drawer_open, :any, required: true
  attr :clipboard_entries, :any, required: true
  attr :codex_error, :any, required: true
  attr :codex_exec_form, :any, required: true
  attr :codex_exec_run, :any, required: true
  attr :codex_live_delta, :any, required: true
  attr :codex_loaded?, :any, required: true
  attr :codex_pending_approval_count, :any, required: true
  attr :codex_pending_requests, :any, required: true
  attr :codex_selected_thread_id, :any, required: true
  attr :codex_threads, :any, required: true
  attr :codex_timeline, :any, required: true
  attr :connect_error, :any, required: true
  attr :connect_info, :any, required: true
  attr :connect_mcp_json, :any, required: true
  attr :connect_new_token, :any, required: true
  attr :connect_tokens, :any, required: true
  attr :context_menu, :any, required: true
  attr :current_user, :any, required: true
  attr :db_isolation, :any, required: true
  attr :default_terminal_sid, :any, required: true
  attr :delete_confirm, :any, required: true
  attr :deploy_drift, :any, required: true
  attr :deploy_failure, :any, required: true
  attr :deploy_in_progress, :any, required: true
  attr :desktop_downloads, :any, default: []
  attr :desktop_terminal?, :any, required: true
  attr :desktop_terminal_pty, :any, required: true
  attr :desktop_terminal_refresh, :any, required: true
  attr :desktop_terminal_status, :any, required: true
  attr :desktop_terminal_term, :any, required: true
  attr :entered_preview_pane_id, :any, required: true
  attr :feature_panes, :any, required: true
  attr :cockpit_geometry, :any, required: true
  attr :inspector_fraction, :any, required: true
  attr :inspector_slots, :any, required: true
  attr :inspector_placement, :any, required: true
  attr :active_inspector_id, :any, required: true
  attr :inspector_focus_id, :any, required: true
  attr :inspector_zoomed?, :any, required: true
  attr :file_diff, :any, required: true
  attr :file_error, :any, required: true
  attr :file_pane_dirty, :any, required: true
  attr :file_symbols, :any, required: true
  attr :flash, :any, required: true
  attr :focused_pane_id, :any, required: true
  attr :git_status, :any, required: true
  attr :grok_permission_requests, :any, required: true
  attr :history_error, :any, required: true
  attr :history_form, :any, required: true
  attr :history_loaded?, :any, required: true
  attr :history_payload, :any, required: true
  attr :history_results, :any, required: true
  attr :host_loc, :any, required: true
  attr :host_path, :any, required: true
  attr :leader_help_open, :any, required: true
  attr :log_ref, :any, required: true
  attr :log_service, :any, required: true
  attr :mobile_nav_focus, :any, required: true
  attr :mobile_nav_open, :any, required: true
  attr :mobile_nav_view, :any, required: true
  attr :new_input, :any, required: true
  attr :node_delete, :any, required: true
  attr :node_rename, :any, required: true
  attr :notif_admin?, :any, required: true
  attr :notif_device_stats, :any, required: true
  attr :notif_devices, :any, required: true
  attr :notif_drawer_open, :any, required: true
  attr :notif_error, :any, required: true
  attr :notif_info, :any, required: true
  attr :notif_loaded?, :any, required: true
  attr :notif_preferences, :any, required: true
  attr :notif_preferences_form, :any, required: true
  attr :notif_unread_count, :any, required: true
  attr :notif_user_id, :any, required: true
  attr :notifications, :any, required: true
  attr :open_file, :any, required: true
  attr :palette_category, :any, required: true
  attr :palette_items, :any, required: true
  attr :palette_result_meta, :any, required: true
  attr :palette_open, :any, required: true
  attr :palette_query, :any, required: true
  attr :palette_selected_idx, :any, required: true
  attr :pane_data, :any, required: true
  attr :pane_history, :any, required: true
  attr :preview_panes, :any, required: true
  attr :project_meta, :any, required: true
  attr :rename_input, :any, required: true
  attr :review_commands, :any, required: true
  attr :run_ledger, :any, required: true
  attr :save_error, :any, required: true
  attr :saved_session_template_tags, :any, required: true
  attr :saved_session_templates, :any, required: true
  attr :search_query, :any, required: true
  attr :search_results, :any, required: true
  attr :search_state, :any, required: true
  attr :selected_dir, :any, required: true
  attr :selected_run_artifacts, :any, required: true
  attr :selected_run_can_retry, :any, required: true
  attr :selected_run_failure_reason, :any, required: true
  attr :selected_run_id, :any, required: true
  attr :selected_run_summary, :any, required: true
  attr :selected_run_timeline, :any, required: true
  attr :session_tabs, :any, required: true
  attr :sessions_sidebar_needs_you, :any, required: true
  attr :sessions_sidebar_open?, :any, required: true
  attr :sessions_sidebar_sort, :any, required: true
  attr :sessions_sidebar_tree, :any, required: true
  attr :shell_button_detail, :any, required: true
  attr :shell_button_label, :any, required: true
  attr :show_hidden_files, :any, required: true
  attr :situation_drawer_open, :any, required: true
  attr :situation_enabled, :any, required: true
  attr :situation_risks, :any, required: true
  attr :streams, :any, required: true
  attr :tab, :any, required: true
  attr :template_duplicate_form, :any, required: true
  attr :template_duplicate_id, :any, required: true
  attr :template_edit_form, :any, required: true
  attr :template_edit_id, :any, required: true
  attr :template_library_open, :any, required: true
  attr :template_preview, :any, required: true
  attr :template_save_form, :any, required: true
  attr :template_tag_filter, :any, required: true
  attr :terminal_mode, :any, required: true
  attr :terminal_sid, :any, required: true
  attr :terminal_surface_pane_id, :any, required: true
  attr :terminal_themes, :any, required: true
  attr :tmux_active_pane_id, :any, required: true
  attr :tmux_active_window_id, :any, required: true
  attr :tmux_mutations_enabled?, :any, required: true
  attr :tmux_panes, :any, required: true
  attr :tmux_rename_session_id, :any, required: true
  attr :tmux_rename_window_id, :any, required: true
  attr :tmux_session, :any, required: true
  attr :tmux_topology_layout_version, :any, required: true
  attr :tmux_topology_structure_version, :any, required: true
  attr :tmux_window_tabs, :any, required: true
  attr :tmux_windows, :any, required: true
  attr :tooling, :any, required: true
  attr :tree, :any, required: true
  attr :tree_error, :any, required: true
  attr :tree_filter, :any, required: true
  attr :ui_highlight_pane_id, :any, required: true
  attr :update_available, :any, required: true
  attr :update_commits_behind, :any, required: true
  attr :window_sidebar_open?, :any, required: true
  attr :window_zoomed?, :any, required: true
  attr :windows_sidebar_sort, :any, required: true
  attr :windows_sidebar_tree, :any, required: true
  attr :workspace, :any, required: true
  attr :workspace_mode_source, :any, required: true
  attr :workspace_route, :any, required: true
  attr :workspace_start_error, :any, required: true

  slot :header_back_nav, required: true, doc: "Frozen navigation back-link (stays owned by Show)."

  def workspace_shell(assigns) do
    # One availability context per render, shared by the hidden leader-key
    # dispatch buttons below — the same module the command palette filters with,
    # so a key is never bound to an action the palette hides (ActionAvailability).
    assigns =
      assigns
      |> assign(:action_ctx, ActionAvailability.context(assigns))
      |> assign(:inspector_entries, List.wrap(assigns[:inspector_slots]))
      |> assign(
        :active_inspector_id,
        CaseinWeb.WorkspaceLive.Show.InspectorFocus.active_id(assigns)
      )
      |> assign(:inspector_region_focused?, is_binary(assigns[:inspector_focus_id]))

    ~H"""
    <div id="palette-anchor" phx-hook="PaletteHook" class="hidden"></div>

    <.palette_overlay
      palette_open={@palette_open}
      palette_query={@palette_query}
      palette_category={@palette_category}
      palette_items={@palette_items}
      palette_result_meta={@palette_result_meta}
      palette_selected_idx={@palette_selected_idx}
    /> {ContextMenu.render_context_menu(assigns)}
    <.template_preview_modal template_preview={@template_preview} />
    <.template_library_drawer
      template_library_open={@template_library_open}
      workspace={@workspace}
      saved_session_templates={@saved_session_templates}
      saved_session_template_tags={@saved_session_template_tags}
      template_tag_filter={@template_tag_filter}
      template_save_form={@template_save_form}
      template_edit_id={@template_edit_id}
      template_edit_form={@template_edit_form}
      template_duplicate_id={@template_duplicate_id}
      template_duplicate_form={@template_duplicate_form}
    /> <Layouts.flash_group flash={@flash} />
    <div id="terminal-activity" phx-hook="TerminalActivity" class="hidden" aria-hidden="true"></div>

    <%!-- Attention surface must stay mounted even when session chrome is gone:
         it reports focused/visible/hidden for quiet-window badge priority. --%>
    <div
      id={"attention-surface-" <> @workspace.id}
      phx-hook="AttentionSurface"
      class="hidden"
      aria-hidden="true"
    >
    </div>

    <div
      id="workspace-leader-root"
      phx-hook="WorkspaceLeader"
      data-terminal-themes={Jason.encode!(@terminal_themes)}
      data-leader-bindings={Jason.encode!(LeaderBindings.key_map())}
      data-tmux-windows={swipe_window_json(@tmux_window_tabs)}
      class="workspace-shell flex h-dvh w-full max-w-full flex-col overflow-x-hidden bg-base-100 text-base-content px-4 pt-1 pb-1.5 max-sm:px-2 max-sm:pt-0 max-sm:pb-0 lg:px-6"
    >
      <% workspace_path = render_path(@host_loc, @host_path) %>
      <%= if @chrome_visible do %>
        <header
          id={"workspace-header-" <> @workspace.id}
          phx-hook="ChromeWidth"
          class="workspace-main-header mb-1 flex w-full max-w-full min-w-0 shrink-0 items-center gap-1 border-b border-base-300/70 px-0.5 pb-0.5 text-xs max-sm:mb-0.5 max-sm:pb-0 max-sm:gap-0.5"
        >
          <div class="header-identity-cluster flex min-w-24 shrink items-center gap-1 overflow-x-clip">
            {render_slot(@header_back_nav)}
            <div
              :if={@tab == "terminal" and match?({:ok, _}, @host_loc)}
              class="flex min-w-0 shrink items-center gap-0.5 max-sm:hidden"
            >
              <SessionBar.session_header_indicator
                workspace_id={@workspace.id}
                tabs={@session_tabs}
                active_id={@terminal_sid}
                active_fallback_label={session_kind_label(@active_session_kind)}
                active_fallback_detail={terminal_session_label(@tmux_session, @terminal_sid)}
                open?={@sessions_sidebar_open?}
              />
              <SessionBar.copy_link_button
                url={
                  SessionBar.share_url(@workspace.id, @terminal_sid, nil, path_base: @workspace_route)
                }
                agent_url={SessionBar.agent_mcp_url(@workspace.id, @tmux_session)}
                label={terminal_session_label(@tmux_session, @terminal_sid)}
                kind="session"
                visible?={true}
              />
            </div>

            <h1
              class="header-p-touch-show header-p-as-block min-w-0 flex-1 truncate text-sm font-semibold leading-none"
              title={workspace_path}
            >
              {workspace_short_name(@workspace.name)}
            </h1>

            <button
              type="button"
              phx-click={
                if(not @desktop_terminal?,
                  do: header_status_action(@workspace, @workspace_start_error)
                )
              }
              disabled={
                @desktop_terminal? or
                  is_nil(header_status_action(@workspace, @workspace_start_error))
              }
              class="header-p-touch-show header-p-as-flex shrink-0 items-center justify-center rounded disabled:cursor-default pointer-coarse:size-8"
              title={
                if(@desktop_terminal?,
                  do: "Local desktop runtime",
                  else: header_status_action_label(@workspace, @workspace_start_error)
                )
              }
              aria-label={
                if(@desktop_terminal?,
                  do: "Local desktop runtime",
                  else: header_status_action_label(@workspace, @workspace_start_error)
                )
              }
            >
              <span
                class={[
                  "size-2 rounded-full",
                  workspace_status_dot_class(@workspace.status)
                ]}
                aria-hidden="true"
              ></span>
            </button>

            <span
              :if={workspace_start_blocked?(@workspace_start_error)}
              id="workspace-start-unavailable"
              class="header-p-touch-hide shrink-0 rounded border border-amber-400/30 bg-amber-400/10 px-2 py-density-label text-density-label font-semibold uppercase tracking-wide text-amber-600 dark:text-amber-300"
            >
              Start unavailable
            </span>
          </div>

          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <div
              id={"header-terminal-pickers-" <> @workspace.id}
              class="header-terminal-pickers flex min-w-0 flex-1 items-center max-sm:hidden"
            >
              <SessionBar.window_tabs
                workspace_id={@workspace.id}
                path_base={@workspace_route}
                terminal_sid={@terminal_sid}
                windows={@tmux_window_tabs}
                topology_version={@tmux_topology_structure_version}
                mutations_allowed?={@tmux_mutations_enabled?}
                rename_window_id={@tmux_rename_window_id}
                terminal_mode={@terminal_mode}
                window_zoomed?={@window_zoomed?}
                class="min-w-0 flex-1"
              />
            </div>
          <% end %>

          <div class="ml-auto flex shrink-0 items-center gap-0.5">
            <.header_overflow_menu
              active_window_pane_count={@active_window_pane_count}
              desktop_downloads={@desktop_downloads}
              desktop_terminal?={@desktop_terminal?}
              host_loc={@host_loc}
              notif_unread_count={@notif_unread_count}
              tab={@tab}
              terminal_mode={@terminal_mode}
              terminal_sid={@terminal_sid}
              tmux_mutations_enabled?={@tmux_mutations_enabled?}
              tmux_session={@tmux_session}
              tmux_window_tabs={@tmux_window_tabs}
              workspace={@workspace}
              workspace_start_error={@workspace_start_error}
              agent_approval_count={
                agent_approval_count(
                  @agent_pending_approval_count,
                  @codex_pending_approval_count,
                  @grok_permission_requests
                )
              }
            />
          </div>
        </header>

        <%!-- Chromeless panes: the focused feature pane's chrome lives here in
             the header (the pane itself is bare) — a file pane's open buffers,
             or a preview's session label. Reserved whenever any file pane
             exists so focus bouncing editor↔terminal doesn't jump the header
             height; hidden when narrow (width), where chrome renders in-pane
             instead (.header-terminal-pickers is display:none there). --%>
        <% focused_id = ui_focused_pane_id(@ui_highlight_pane_id, @tmux_active_pane_id) %>
        <% file_strip = focused_file_strip(@feature_panes, focused_id, @file_pane_dirty) %>
        <% preview_chrome = focused_preview_chrome(@preview_panes, focused_id, @tmux_session) %>
        <div
          :if={
            @tab == "terminal" and match?({:ok, _}, @host_loc) and
              (file_strip != nil or preview_chrome != nil or any_file_pane?(@feature_panes))
          }
          class="header-terminal-pickers file-pane-strip-row -mt-0.5 mb-1 flex h-7 shrink-0 items-center border-b border-base-300/70 max-sm:hidden"
        >
          <.file_pane_tab_strip
            :if={file_strip}
            strip={file_strip}
            class="min-w-0 flex-1 self-stretch"
          />
          <div
            :if={file_strip == nil and preview_chrome != nil}
            title={preview_chrome.title}
            class={[
              "min-w-0 truncate rounded border px-2 py-density-body text-density-body font-medium leading-none",
              if(preview_chrome.mismatch?,
                do: "border-amber-300/50 bg-amber-400/10 text-amber-600 dark:text-amber-200",
                else: "border-base-300 bg-base-200/60 text-base-content/70"
              )
            ]}
          >
            {preview_chrome.label}
          </div>
          <div
            :if={file_strip == nil and preview_chrome == nil}
            class="flex items-center px-2 text-density-body text-base-content/40"
          >
            No file pane focused
          </div>
        </div>
      <% else %>
        <%!-- Thin reveal strip when chrome is hidden (focus mode).
             Click or keyboard shortcut brings the header + utility bar back.
             Only shown in the outer container so it works across all tabs.
             On touch it stays taller than the desktop hairline because it is
             the *only* way back to the chrome (no Ctrl+Shift+F on a phone) and
             it carries the session/window label — but only just: focus mode
             exists to give rows back to the terminal, so every px above a
             thumb-reachable target is a px the operator asked us not to
             spend. --%>
        <div
          class="mb-1 pointer-coarse:mb-0.5 h-1.5 pointer-coarse:h-5 w-full cursor-pointer rounded bg-base-300/40 hover:bg-emerald-400/40 active:bg-emerald-400/60 transition-colors duration-motion-state ease-motion-state flex items-center justify-center pointer-coarse:justify-between pointer-coarse:gap-2 pointer-coarse:px-2"
          phx-click="terminal:toggle_chrome"
          title="Show header. Shortcut: Ctrl/Cmd + Shift + F"
          aria-label="Show header and utility bar"
        >
          <span class="sr-only">Show chrome</span>
          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <% win = active_tmux_window_name(@tmux_active_window_id, @tmux_windows) %>
            <span class="hidden pointer-coarse:flex min-w-0 items-center gap-1.5 text-density-body leading-none text-base-content/70">
              <span
                class={["size-2 shrink-0 rounded-full", workspace_status_dot_class(@workspace.status)]}
                aria-hidden="true"
              ></span>
              <span class="truncate font-medium text-base-content/80">
                {mobile_active_session_label(
                  @terminal_sid,
                  @default_terminal_sid,
                  @shell_button_label,
                  @session_tabs
                )}
              </span>

              <%= if is_binary(win) and win != "" do %>
                <span class="shrink-0 text-base-content/40">·</span>
                <span class="truncate text-base-content/55">{win}</span>
              <% end %>
            </span>
          <% end %>

          <span
            class="hidden pointer-coarse:block shrink-0 leading-none text-base-content/40"
            aria-hidden="true"
          >
            ▾
          </span>
        </div>
      <% end %>

      <.agent_write_locked_banner
        workspace={@workspace}
        agent_write_unlock={@agent_write_unlock}
      />

      <%!-- Central leader-key dispatch targets. WorkspaceLeader routes every
            C-b second key to a click on [data-leader-action=...], so each
            action lives on exactly one element here (docs/leader_keys.md) —
            outside the chrome block, so bindings keep working in focus mode.
            Visible chrome buttons share the same phx-click handlers but carry
            no data-leader-action. Exceptions: C-b s stays on the session
            dropdown <summary>; C-b w opens the transient window sidebar; and
            window-by-index targets live on the window tabs. --%>
      <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
        <div class="hidden" aria-hidden="true">
          <button
            type="button"
            tabindex="-1"
            data-leader-action="copy-link"
            data-copy-session-link={
              current_share_url(@workspace, @terminal_sid, %{
                tmux_active_window_id: @tmux_active_window_id,
                workspace_route: @workspace_route,
                tmux_panes: @tmux_panes,
                tmux_active_pane_id: @tmux_active_pane_id,
                window_zoomed?: @window_zoomed?
              })
            }
            data-copy-link-kind="view"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="detach"
            phx-click="terminal:switch_to_shell"
          ></button>
          <button type="button" tabindex="-1" data-leader-action="palette" phx-click="palette:open"></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="help"
            phx-click="leader_help:toggle"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="last-window"
            phx-click="tmux:last_window"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="last-pane"
            phx-click="pane:navigate"
            phx-value-dir="last"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="prev-session"
            phx-click="terminal:cycle_session"
            phx-value-dir="prev"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="next-session"
            phx-click="terminal:cycle_session"
            phx-value-dir="next"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="next-window"
            phx-click="tmux:cycle_window"
            phx-value-dir="next"
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="prev-window"
            phx-click="tmux:cycle_window"
            phx-value-dir="prev"
          ></button>
          <%!-- No data-confirm: closing is deferred and undoable for a grace period,
          so the undo toast (and C-b r) stands in for the prompt. --%>
          <button
            :if={@tmux_active_window_id}
            type="button"
            tabindex="-1"
            data-leader-action="kill-window"
            phx-click="tmux:kill_window"
            phx-value-window-id={@tmux_active_window_id}
          ></button>
          <button
            type="button"
            tabindex="-1"
            data-leader-action="restore-window"
            phx-click="tmux:restore_window"
          ></button>
          <button
            :if={@tmux_active_window_id}
            type="button"
            tabindex="-1"
            data-leader-action="rename-window"
            phx-click="tmux:rename_start"
            phx-value-window-id={@tmux_active_window_id}
          ></button>
          <button
            :if={is_binary(@tmux_session)}
            type="button"
            tabindex="-1"
            data-leader-action="rename-session"
            phx-click="terminal:rename_session_start"
            phx-value-session-id={@terminal_sid}
          ></button>
          <%= if ActionAvailability.available?("tmux:new_window", @action_ctx) do %>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="new-window"
              phx-click="tmux:new_window"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="new-window-tab"
              phx-click="tmux:new_window_tab"
            ></button>
          <% end %>
          <%!-- Pane focus arrows work across all tmux pane tiles. --%>
          <%= if ActionAvailability.available?("pane:navigate", @action_ctx) do %>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-left"
              phx-click="pane:navigate"
              phx-value-dir="left"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-down"
              phx-click="pane:navigate"
              phx-value-dir="down"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-up"
              phx-click="pane:navigate"
              phx-value-dir="up"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-right"
              phx-click="pane:navigate"
              phx-value-dir="right"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-next"
              phx-click="pane:navigate"
              phx-value-dir="next"
            ></button>
          <% end %>

          <%= if ActionAvailability.available?("split_right", @action_ctx) do %>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="close-pane"
              phx-click="pane:close_focused"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="split-right"
              phx-click="split_right"
            ></button>
            <button type="button" tabindex="-1" data-leader-action="split-down" phx-click="split_down"></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="zoom"
              phx-click="pane:zoom_focused"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-swap-previous"
              phx-click="pane:swap_previous"
            ></button>
            <button
              type="button"
              tabindex="-1"
              data-leader-action="pane-swap-next"
              phx-click="pane:swap_next"
            ></button>
          <% end %>
        </div>
      <% end %>

      <div class="min-h-0 flex-1">
        <%= if @tab == "terminal" do %>
          <% geometry = @cockpit_geometry || Geometry.terminal_only() %>
          <% inspectors_open? = Geometry.inspector_open?(geometry) %>
          <% inspector_zoomed? = inspectors_open? and @inspector_zoomed? == true %>
          <% placement = Geometry.placement(geometry) %>
          <% fraction = Geometry.inspector_fraction(geometry) %>
          <div
            id={"cockpit-split-" <> @workspace.id}
            data-cockpit-split={if(inspectors_open?, do: "open", else: "closed")}
            data-inspector-placement={if(inspectors_open?, do: Atom.to_string(placement), else: nil)}
            data-inspector-fraction={if(inspectors_open?, do: to_string(fraction), else: nil)}
            data-inspector-zoomed={to_string(inspector_zoomed?)}
            data-inspector-focused={to_string(@inspector_region_focused?)}
            data-geometry-kind={geometry.kind}
            class={[
              "flex h-full min-h-0 min-w-0",
              inspectors_open? && not inspector_zoomed? && placement == :bottom && "flex-col",
              inspectors_open? && not inspector_zoomed? && placement == :right && "flex-row",
              inspector_zoomed? && "flex-col"
            ]}
          >
            <div
              id={"terminal-region-" <> @workspace.id}
              data-terminal-region="true"
              data-inspector-open={to_string(inspectors_open?)}
              data-inspector-zoomed={to_string(inspector_zoomed?)}
              class={[
                "min-h-0 min-w-0 overflow-hidden",
                not inspectors_open? && "h-full w-full flex-1",
                inspector_zoomed? && "hidden"
              ]}
              style={if(inspector_zoomed?, do: nil, else: terminal_region_style(geometry))}
            >
              <.terminal_tab
                active_window_pane_count={@active_window_pane_count}
                chrome_visible={@chrome_visible}
                default_terminal_sid={@default_terminal_sid}
                desktop_terminal?={@desktop_terminal?}
                desktop_terminal_pty={@desktop_terminal_pty}
                desktop_terminal_refresh={@desktop_terminal_refresh}
                desktop_terminal_status={@desktop_terminal_status}
                desktop_terminal_term={@desktop_terminal_term}
                entered_preview_pane_id={@entered_preview_pane_id}
                feature_panes={@feature_panes}
                file_pane_dirty={@file_pane_dirty}
                focused_pane_id={@focused_pane_id}
                host_loc={@host_loc}
                mobile_nav_focus={@mobile_nav_focus}
                mobile_nav_open={@mobile_nav_open}
                mobile_nav_view={@mobile_nav_view}
                pane_data={@pane_data}
                pane_history={@pane_history}
                preview_panes={@preview_panes}
                session_tabs={@session_tabs}
                sessions_sidebar_needs_you={@sessions_sidebar_needs_you}
                sessions_sidebar_open?={@sessions_sidebar_open?}
                sessions_sidebar_sort={@sessions_sidebar_sort}
                sessions_sidebar_tree={@sessions_sidebar_tree}
                shell_button_detail={@shell_button_detail}
                shell_button_label={@shell_button_label}
                terminal_mode={@terminal_mode}
                terminal_sid={@terminal_sid}
                terminal_surface_pane_id={@terminal_surface_pane_id}
                terminal_themes={@terminal_themes}
                tmux_active_pane_id={@tmux_active_pane_id}
                tmux_mutations_enabled?={@tmux_mutations_enabled?}
                tmux_rename_session_id={@tmux_rename_session_id}
                tmux_rename_window_id={@tmux_rename_window_id}
                tmux_session={@tmux_session}
                tmux_topology_layout_version={@tmux_topology_layout_version}
                tmux_topology_structure_version={@tmux_topology_structure_version}
                tmux_window_tabs={@tmux_window_tabs}
                tmux_windows={@tmux_windows}
                ui_highlight_pane_id={@ui_highlight_pane_id}
                window_sidebar_open?={@window_sidebar_open?}
                window_zoomed?={@window_zoomed?}
                windows_sidebar_sort={@windows_sidebar_sort}
                windows_sidebar_tree={@windows_sidebar_tree}
                workspace={@workspace}
                workspace_route={@workspace_route}
                workspace_start_error={@workspace_start_error}
                agent_approval_count={
                  agent_approval_count(
                    @agent_pending_approval_count,
                    @codex_pending_approval_count,
                    @grok_permission_requests
                  )
                }
              />
            </div>
            <aside
              :if={inspectors_open?}
              id={"inspector-region-" <> @workspace.id}
              data-inspector-region="true"
              data-inspector-placement={Atom.to_string(placement)}
              data-inspector-focused={to_string(@inspector_region_focused?)}
              data-inspector-zoomed={to_string(inspector_zoomed?)}
              data-active-inspector-id={@active_inspector_id}
              class={[
                "min-h-0 min-w-0 overflow-hidden border-base-300/70 bg-base-200/40",
                not inspector_zoomed? && placement == :right && "border-l",
                not inspector_zoomed? && placement == :bottom && "border-t",
                inspector_zoomed? && "h-full w-full flex-1 border-0",
                @inspector_region_focused? && "ring-1 ring-inset ring-primary/70"
              ]}
              style={
                if(inspector_zoomed?,
                  do: "flex: 1 1 auto; max-width: 100%; max-height: 100%",
                  else: inspector_region_style(geometry)
                )
              }
            >
              <.inspector_region
                workspace_id={@workspace.id}
                entries={@inspector_entries}
                placement={placement}
                active_id={@active_inspector_id}
                focused?={@inspector_region_focused?}
                zoomed?={inspector_zoomed?}
                git_status={@git_status}
                open_file={@open_file}
                file_diff={@file_diff}
              />
            </aside>
          </div>
        <% end %>
        <.files_panel
          :if={@tab == "files"}
          host_loc={@host_loc}
          selected_dir={@selected_dir}
          new_input={@new_input}
          tree_error={@tree_error}
          tree={@tree}
          project_meta={@project_meta}
          tooling={@tooling}
          open_file={@open_file}
          file_symbols={@file_symbols}
          rename_input={@rename_input}
          delete_confirm={@delete_confirm}
          save_error={@save_error}
          file_error={@file_error}
          node_rename={@node_rename}
          node_delete={@node_delete}
          show_hidden_files={@show_hidden_files}
          tree_filter={@tree_filter}
        />
        <.search_panel
          :if={@tab == "search"}
          search_query={@search_query}
          search_results={@search_results}
          search_state={@search_state}
        />
        <.diff_panel
          :if={@tab == "diff"}
          git_status={@git_status}
          open_file={@open_file}
          file_diff={@file_diff}
        />
        <.artifact_gallery_panel
          :if={@tab == "artifacts"}
          artifact_projects={@artifact_projects}
          artifact_projects_error={@artifact_projects_error}
          artifact_selected_id={@artifact_selected_id}
        />
        <.run_panel
          :if={@tab == "run"}
          host_loc={@host_loc}
          active_run={@active_run}
          review_commands={@review_commands}
          agent_write_unlock={@agent_write_unlock}
          run_ledger={@run_ledger}
          selected_run_id={@selected_run_id}
          selected_run_timeline={@selected_run_timeline}
          selected_run_summary={@selected_run_summary}
          selected_run_failure_reason={@selected_run_failure_reason}
          selected_run_can_retry={@selected_run_can_retry}
          selected_run_artifacts={@selected_run_artifacts}
          codex_exec_form={@codex_exec_form}
          codex_exec_run={@codex_exec_run}
        />
        <.live_component
          :if={@tab == "proposals"}
          module={CaseinWeb.WorkspaceLive.ProposalPanelComponent}
          id="proposal-panel"
          workspace={@workspace}
          current_user={@current_user}
          workspace_mode_source={@workspace_mode_source}
          db_isolation={@db_isolation}
          host_path={@host_path}
        />
        <.logs_panel
          :if={@tab == "logs"}
          log_service={@log_service}
          log_ref={@log_ref}
          streams={@streams}
        />
        <.history_panel
          :if={@tab == "history"}
          workspace_id={@workspace.id}
          history_form={@history_form}
          history_results={@history_results}
          history_payload={@history_payload}
          history_error={@history_error}
          history_loaded?={@history_loaded?}
          agent_activity_loaded?={@codex_loaded?}
          agent_threads={@codex_threads}
          selected_agent_thread_id={@codex_selected_thread_id}
          agent_timeline={@codex_timeline}
          agent_live_delta={@codex_live_delta}
          agent_activity_error={@codex_error}
        />
      </div>
    </div>

    <.live_component
      module={CaseinWeb.WorkspaceLive.AuditDrawerComponent}
      id="audit-drawer"
      open={@audit_drawer_open}
      workspace={@workspace}
      current_user={@current_user}
    />
    <.situation_badge enabled={@situation_enabled} risks={@situation_risks} />
    <.situation_drawer
      enabled={@situation_enabled}
      open={@situation_drawer_open}
      risks={@situation_risks}
      workspace={@workspace}
    />
    <NotificationsDrawer.notifications_drawer
      open={@notif_drawer_open}
      loaded?={@notif_loaded?}
      notifications={@notifications}
      unread_count={@notif_unread_count}
      user_id={@notif_user_id}
      error={@notif_error}
      info={@notif_info}
      preferences={@notif_preferences}
      preferences_form={@notif_preferences_form}
      admin?={@notif_admin?}
      device_stats={@notif_device_stats}
      devices={@notif_devices}
      deploy_failure={@deploy_failure}
      deploy_in_progress={@deploy_in_progress}
      update_available={@update_available}
      deploy_drift={@deploy_drift}
      update_commits_behind={@update_commits_behind}
      codex_pending_requests={@codex_pending_requests}
      grok_permission_requests={@grok_permission_requests}
    />
    <ClipboardDrawer.clipboard_drawer
      open={@clipboard_drawer_open}
      entries={@clipboard_entries}
      count={@clipboard_count}
    />
    <.leader_help_overlay
      open={@leader_help_open}
      connect_new_token={@connect_new_token}
      connect_mcp_json={@connect_mcp_json}
      connect_tokens={@connect_tokens}
      connect_error={@connect_error}
      connect_info={@connect_info}
    />
    """
  end

  # The window-swipe bar names the window it will land on. It used to read that
  # off the header's tab strip — which focus mode does not render at all, so on
  # a phone (where focus mode is the point) every swipe reported "No other
  # window" no matter how many were open. Carry the little the bar needs on the
  # always-mounted leader root instead; the strip stays the preferred source
  # when it is there, since a drag can reorder it client-side.
  defp swipe_window_json(tmux_window_tabs) do
    tmux_window_tabs
    |> List.wrap()
    |> Enum.map(
      &%{
        index: to_string(&1.index),
        name: &1.display_name,
        activity: to_string(&1.activity_state),
        attention: to_string(&1.attention),
        active: &1.active? == true
      }
    )
    |> Jason.encode!()
  end

  # These helpers take explicit values rather than the whole `assigns` map on
  # purpose: referencing bare `assigns` inside ~H is a strong taint, so LiveView
  # gives up and re-renders that dynamic on every update. Naming the inputs keeps
  # each expression change-tracked against just the assigns it actually reads.
  defp agent_approval_count(agent_pending, codex_pending, grok_requests) do
    agent_pending || (codex_pending || 0) + length(grok_requests || [])
  end

  defp current_share_url(workspace, terminal_sid, deep_link_assigns) do
    SessionBar.share_url(
      workspace.id,
      terminal_sid,
      deep_link_assigns[:tmux_active_window_id],
      CaseinWeb.WorkspaceLive.Show.ViewDeepLink.share_query_opts(deep_link_assigns)
    )
  end

  defp active_tmux_window_name(tmux_active_window_id, tmux_windows) do
    CaseinWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{
      assigns: %{tmux_active_window_id: tmux_active_window_id, tmux_windows: tmux_windows}
    })
  end

  defp mobile_active_session_label(
         terminal_sid,
         default_terminal_sid,
         shell_button_label,
         session_tabs
       ) do
    if terminal_sid == default_terminal_sid do
      case shell_button_label do
        label when is_binary(label) and label != "" -> label
        _ -> "Shell"
      end
    else
      case Enum.find(session_tabs, &(&1.id == terminal_sid)) do
        %{label: label} when is_binary(label) and label != "" -> label
        _ -> "Session"
      end
    end
  end

  # --- inspector region (LiveView-owned viewports, issue #690) ------------------

  defp terminal_region_style(geometry) do
    case Geometry.terminal_basis_percent(geometry) do
      nil ->
        nil

      pct ->
        case Geometry.placement(geometry) do
          :bottom -> "flex: 0 0 #{pct}%; max-height: #{pct}%"
          _ -> "flex: 0 0 #{pct}%; max-width: #{pct}%"
        end
    end
  end

  defp inspector_region_style(geometry) do
    case Geometry.inspector_basis_percent(geometry) do
      nil ->
        nil

      pct ->
        case Geometry.placement(geometry) do
          :bottom -> "flex: 0 0 #{pct}%; max-height: #{pct}%"
          _ -> "flex: 0 0 #{pct}%; max-width: #{pct}%"
        end
    end
  end

  attr :workspace_id, :string, required: true
  attr :entries, :list, required: true
  attr :placement, :atom, required: true
  attr :active_id, :any, required: true
  attr :focused?, :boolean, required: true
  attr :zoomed?, :boolean, required: true
  attr :git_status, :any, required: true
  attr :open_file, :any, required: true
  attr :file_diff, :any, required: true

  defp inspector_region(assigns) do
    ~H"""
    <div class="flex h-full min-h-0 flex-col" data-inspector-chrome="true">
      <div class="flex shrink-0 items-center gap-1 border-b border-base-300/60 bg-base-200/80 px-1.5 py-1">
        <div
          id={"inspector-tabs-" <> @workspace_id}
          class="flex min-w-0 flex-1 items-center gap-0.5 overflow-x-auto"
          role="tablist"
          aria-label="Inspector panes"
        >
          <button
            :for={{entry, index} <- Enum.with_index(@entries)}
            id={"inspector-tab-" <> entry.id}
            type="button"
            role="tab"
            aria-selected={to_string(entry.id == @active_id)}
            data-inspector-tab={entry.id}
            data-pane-kind="inspector"
            data-pane-index={index}
            data-active={to_string(entry.id == @active_id)}
            data-focused={to_string(@focused? and entry.id == @active_id)}
            phx-click="inspector:select"
            phx-value-id={entry.id}
            class={[
              "group flex max-w-[14rem] items-center gap-1.5 rounded-md px-2 py-1 text-left text-density-body transition",
              entry.id == @active_id &&
                "bg-base-100 text-base-content shadow-sm ring-1 ring-base-300/80",
              entry.id != @active_id &&
                "text-base-content/60 hover:bg-base-100/70 hover:text-base-content/80",
              (@focused? and entry.id == @active_id) && "ring-primary/60"
            ]}
          >
            <span class="font-mono text-density-label text-base-content/40">{index}</span>
            <span class="truncate font-medium">{inspector_title(entry)}</span>
            <span class="rounded bg-base-300/50 px-1 py-density-badge font-mono text-density-badge uppercase tracking-wide text-base-content/45">
              {inspector_kind_label(entry)}
            </span>
            <span
              role="button"
              tabindex="-1"
              data-inspector-tab-close={entry.id}
              phx-click="inspector:close"
              phx-value-id={entry.id}
              class="ml-0.5 rounded p-0.5 text-base-content/35 opacity-70 hover:bg-base-300/60 hover:text-base-content/80 group-hover:opacity-100"
              aria-label={"Close " <> inspector_title(entry)}
            >
              <.icon name="hero-x-mark" class="h-3 w-3" />
            </span>
          </button>
        </div>
        <div class="flex shrink-0 items-center gap-1 pl-1 text-density-label text-base-content/45">
          <span :if={@zoomed?} class="rounded bg-primary/15 px-1.5 py-0.5 font-medium text-primary">
            zoomed
          </span>
          <span class="font-mono uppercase tracking-wide">z/x</span>
        </div>
      </div>

      <div class="min-h-0 flex-1 overflow-auto">
        <div
          :for={entry <- @entries}
          id={"inspector-pane-" <> entry.id}
          data-inspector-pane-id={entry.id}
          data-inspector-kind={inspector_kind_attr(entry.kind)}
          data-pane-kind="inspector"
          data-focused={to_string(@focused? and entry.id == @active_id)}
          hidden={entry.id != @active_id}
          class={[
            "flex h-full min-h-0 flex-col",
            entry.id != @active_id && "hidden",
            (@focused? and entry.id == @active_id) && "bg-base-100/40"
          ]}
        >
          <div class="flex shrink-0 items-center justify-between gap-2 border-b border-base-300/40 px-3 py-1.5">
            <div class="min-w-0">
              <div class="truncate text-sm font-medium text-base-content/90">
                {inspector_title(entry)}
              </div>
              <div class="truncate font-mono text-density-body text-base-content/45">
                {entry.id}
              </div>
            </div>
            <button
              type="button"
              id={"inspector-close-" <> entry.id}
              phx-click="inspector:close"
              phx-value-id={entry.id}
              class="btn btn-ghost btn-xs"
              data-leader-second-key="x"
            >
              Close
            </button>
          </div>
          <div class="min-h-0 flex-1 overflow-auto p-3 text-sm text-base-content/80">
            <%= if entry.kind == :diff do %>
              <.diff_panel
                git_status={@git_status}
                open_file={@open_file}
                file_diff={@file_diff}
              />
            <% else %>
              <div class="rounded-md border border-base-300/50 bg-base-100/70 px-3 py-2">
                <div class="text-density-body uppercase tracking-wide text-base-content/45">
                  {inspector_kind_label(entry)}
                </div>
                <div class="mt-1 font-medium">{inspector_title(entry)}</div>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp inspector_title(%{title: title}) when is_binary(title) and title != "", do: title

  defp inspector_title(%{kind: kind}) when is_atom(kind),
    do: kind |> Atom.to_string() |> String.capitalize()

  defp inspector_title(_), do: "Inspector"

  defp inspector_kind_label(%{kind: kind}) when is_atom(kind), do: Atom.to_string(kind)
  defp inspector_kind_label(%{kind: kind}) when is_binary(kind), do: kind
  defp inspector_kind_label(_), do: "insp"

  defp inspector_kind_attr(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp inspector_kind_attr(kind) when is_binary(kind), do: kind
  defp inspector_kind_attr(_), do: "inspector"
end
