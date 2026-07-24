defmodule CaseinWeb.WorkspaceLive.Show.WorkspaceShell do
  @moduledoc false

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

  alias CaseinWeb.NotificationsDrawer
  alias CaseinWeb.WorkspaceLive.Show.ContextMenu
  alias CaseinWeb.WorkspaceLive.Show.SessionBar

  slot :header_back_nav, required: true, doc: "Frozen navigation back-link (stays owned by Show)."

  def workspace_shell(assigns) do
    ~H"""
    <div id="palette-anchor" phx-hook="PaletteHook" class="hidden"></div>

    <.palette_overlay
      palette_open={@palette_open}
      palette_query={@palette_query}
      palette_category={@palette_category}
      palette_items={@palette_items}
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
      class="workspace-shell flex h-dvh w-full max-w-full flex-col overflow-x-hidden bg-base-100 text-base-content px-4 pt-1 pb-1.5 pointer-coarse:px-2 pointer-coarse:pt-0 pointer-coarse:pb-0 lg:px-6"
    >
      <% workspace_path = render_path(@host_loc, @host_path) %>
      <%= if @chrome_visible do %>
        <header
          id={"workspace-header-" <> @workspace.id}
          phx-hook="ChromeWidth"
          class="workspace-main-header mb-1 flex w-full max-w-full min-w-0 shrink-0 items-center gap-1 border-b border-base-300/70 px-0.5 pb-0.5 text-xs pointer-coarse:mb-0.5 pointer-coarse:pb-0 pointer-coarse:gap-0.5"
        >
          <div class="header-identity-cluster flex min-w-24 shrink items-center gap-1 overflow-x-clip">
            {render_slot(@header_back_nav)}
            <div
              :if={@tab == "terminal" and match?({:ok, _}, @host_loc)}
              class="flex min-w-0 shrink items-center gap-0.5 pointer-coarse:hidden"
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
              class="header-p-touch-hide shrink-0 rounded border border-amber-400/30 bg-amber-400/10 px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-600 dark:text-amber-300"
            >
              Start unavailable
            </span>
          </div>

          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <div
              id={"header-terminal-pickers-" <> @workspace.id}
              class="header-terminal-pickers flex min-w-0 flex-1 items-center pointer-coarse:hidden"
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

          <div class="ml-auto flex shrink-0 items-center gap-0.5 pointer-coarse:gap-0.5">
            <.header_overflow_menu {header_overflow_attrs(assigns)} />
          </div>
        </header>

        <%!-- Chromeless panes: the focused feature pane's chrome lives here in
             the header (the pane itself is bare) — a file pane's open buffers,
             or a preview's session label. Reserved whenever any file pane
             exists so focus bouncing editor↔terminal doesn't jump the header
             height; hidden on touch/narrow, where chrome renders in-pane
             instead (.header-terminal-pickers is display:none there). --%>
        <% focused_id = ui_focused_pane_id(@ui_highlight_pane_id, @tmux_active_pane_id) %>
        <% file_strip = focused_file_strip(@feature_panes, focused_id, @file_pane_dirty) %>
        <% preview_chrome = focused_preview_chrome(@preview_panes, focused_id, @tmux_session) %>
        <div
          :if={
            @tab == "terminal" and match?({:ok, _}, @host_loc) and
              (file_strip != nil or preview_chrome != nil or any_file_pane?(@feature_panes))
          }
          class="header-terminal-pickers file-pane-strip-row -mt-0.5 mb-1 flex h-7 shrink-0 items-center border-b border-base-300/70 pointer-coarse:hidden"
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
              "min-w-0 truncate rounded border px-2 py-0.5 text-[11px] font-medium leading-none",
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
            class="flex items-center px-2 text-[11px] text-base-content/40"
          >
            No file pane focused
          </div>
        </div>
      <% else %>
        <%!-- Thin reveal strip when chrome is hidden (focus mode).
             Click or keyboard shortcut brings the header + utility bar back.
             Only shown in the outer container so it works across all tabs. --%>
        <div
          class="mb-1 pointer-coarse:mb-0.5 h-1.5 pointer-coarse:h-7 w-full cursor-pointer rounded bg-base-300/40 hover:bg-emerald-400/40 active:bg-emerald-400/60 transition-colors flex items-center justify-center pointer-coarse:justify-between pointer-coarse:gap-2 pointer-coarse:px-2"
          phx-click="terminal:toggle_chrome"
          title="Show header. Shortcut: Ctrl/Cmd + Shift + F"
          aria-label="Show header and utility bar"
        >
          <span class="sr-only">Show chrome</span>
          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <% win = active_tmux_window_name(assigns) %>
            <span class="hidden pointer-coarse:flex min-w-0 items-center gap-1.5 text-[11px] leading-none text-base-content/70">
              <span
                class={["size-2 shrink-0 rounded-full", workspace_status_dot_class(@workspace.status)]}
                aria-hidden="true"
              ></span>
              <span class="truncate font-medium text-base-content/80">
                {mobile_active_session_label(assigns)}
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
            data-copy-session-link={current_share_url(assigns)}
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
            phx-click={JS.toggle(to: "#leader-cheatsheet")}
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
          <button
            :if={@tmux_active_window_id}
            type="button"
            tabindex="-1"
            data-leader-action="kill-window"
            data-confirm="Kill this tmux window and everything running in it?"
            phx-click="tmux:kill_window"
            phx-value-window-id={@tmux_active_window_id}
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
          <%= if @tmux_mutations_enabled? do %>
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
          <%= if is_binary(@tmux_session) do %>
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

          <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
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
        <.terminal_tab :if={@tab == "terminal"} {terminal_tab_attrs(assigns)} />
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
      codex_approvals={@codex_approvals}
      grok_permission_requests={@grok_permission_requests}
    />
    <.leader_help_overlay
      connect_new_token={@connect_new_token}
      connect_mcp_json={@connect_mcp_json}
      connect_tokens={@connect_tokens}
      connect_error={@connect_error}
      connect_info={@connect_info}
    />
    """
  end

  defp header_overflow_attrs(assigns) do
    assigns
    |> Map.take([
      :workspace,
      :workspace_start_error,
      :desktop_terminal?,
      :tab,
      :host_loc,
      :tmux_mutations_enabled?,
      :tmux_window_tabs,
      :terminal_mode,
      :tmux_session,
      :terminal_sid,
      :active_window_pane_count,
      :notif_unread_count
    ])
    |> Map.put(:agent_approval_count, agent_approval_count(assigns))
  end

  defp terminal_tab_attrs(assigns) do
    assigns
    |> Map.take([
      :workspace,
      :host_loc,
      :terminal_mode,
      :tmux_windows,
      :preview_panes,
      :feature_panes,
      :tmux_session,
      :ui_highlight_pane_id,
      :tmux_active_pane_id,
      :window_zoomed?,
      :tmux_mutations_enabled?,
      :entered_preview_pane_id,
      :terminal_surface_pane_id,
      :pane_history,
      :terminal_themes,
      :focused_pane_id,
      :file_pane_dirty,
      :pane_data,
      :desktop_terminal?,
      :desktop_terminal_term,
      :desktop_terminal_pty,
      :desktop_terminal_status,
      :desktop_terminal_refresh,
      :workspace_start_error,
      :mobile_nav_open,
      :mobile_nav_view,
      :mobile_nav_focus,
      :session_tabs,
      :terminal_sid,
      :default_terminal_sid,
      :shell_button_label,
      :shell_button_detail,
      :workspace_route,
      :active_window_pane_count,
      :tmux_window_tabs,
      :tmux_topology_structure_version,
      :tmux_topology_layout_version,
      :tmux_rename_window_id,
      :tmux_rename_session_id,
      :window_sidebar_open?,
      :sessions_sidebar_open?,
      :sessions_sidebar_tree,
      :sessions_sidebar_needs_you,
      :windows_sidebar_tree,
      :sessions_sidebar_sort,
      :windows_sidebar_sort,
      :chrome_visible
    ])
    |> Map.put(:agent_approval_count, agent_approval_count(assigns))
  end

  defp agent_approval_count(assigns) do
    (assigns[:codex_pending_approval_count] || 0) +
      length(assigns[:grok_permission_requests] || [])
  end

  defp current_share_url(assigns) do
    SessionBar.share_url(
      assigns.workspace.id,
      assigns.terminal_sid,
      assigns[:tmux_active_window_id],
      CaseinWeb.WorkspaceLive.Show.ViewDeepLink.share_query_opts(assigns)
    )
  end

  defp active_tmux_window_name(assigns) do
    CaseinWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{assigns: assigns})
  end

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
end
