defmodule DevIdeWeb.WorkspaceLive.Show.WorkspaceShell do
  @moduledoc false

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.UI
  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome
  import DevIdeWeb.WorkspaceLive.Show.RunPanel
  import DevIdeWeb.WorkspaceLive.Show.SidePanels
  import DevIdeWeb.WorkspaceLive.Show.TemplatePanels
  import DevIdeWeb.WorkspaceLive.Show.LogsPanel

  import DevIdeWeb.WorkspaceLive.Show.WorkspaceHeader,
    only: [
      header_overflow_menu: 1,
      workspace_start_blocked?: 1,
      workspace_status_dot_class: 1,
      header_status_action: 2,
      header_status_action_label: 2
    ]

  import DevIdeWeb.WorkspaceLive.Show.TerminalPanel, only: [terminal_tab: 1]
  import DevIdeWeb.WorkspaceLive.Show.PalettePanel, only: [palette_overlay: 1]
  import DevIdeWeb.WorkspaceLive.Show.LeaderHelp, only: [leader_help_overlay: 1]

  alias DevIdeWeb.WorkspaceLive.Show.ContextMenu
  alias DevIdeWeb.WorkspaceLive.Show.SessionBar
  alias DevIdeWeb.WorkspaceLive.Show.TerminalState
  alias Phoenix.LiveView.JS

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
    />
    {ContextMenu.render_context_menu(assigns)}
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
    />
    <Layouts.flash_group flash={@flash} />
    <div id="terminal-activity" phx-hook="TerminalActivity" class="hidden" aria-hidden="true"></div>
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
            <h1
              class="header-p-touch-show header-p-as-block min-w-0 flex-1 truncate text-sm font-semibold leading-none"
              title={workspace_path}
            >
              {workspace_short_name(@workspace.name)}
            </h1>
            <button
              type="button"
              phx-click={header_status_action(@workspace, @workspace_start_error)}
              disabled={is_nil(header_status_action(@workspace, @workspace_start_error))}
              class="header-p-touch-show header-p-as-flex shrink-0 items-center justify-center rounded disabled:cursor-default pointer-coarse:size-8"
              title={header_status_action_label(@workspace, @workspace_start_error)}
              aria-label={header_status_action_label(@workspace, @workspace_start_error)}
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
            <button
              :if={
                @tab == "terminal" and @terminal_mode in [:raw, :raw_ghostty] and
                  match?({:ok, _}, @host_loc)
              }
              type="button"
              id="header-session-copy"
              phx-hook="CopyText"
              data-copy-text={terminal_session_label(@tmux_session, @terminal_sid)}
              class="header-p-low header-p-touch-show header-p-as-inline shrink-0 rounded font-mono text-[11px] text-base-content/50 active:text-base-content data-[copied]:text-emerald-500"
              title="Copy tmux session name"
              aria-label={"Copy tmux session " <> terminal_session_label(@tmux_session, @terminal_sid)}
            >
              {terminal_session_label(@tmux_session, @terminal_sid)}
            </button>
          </div>
          <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
            <div
              id={"header-terminal-pickers-" <> @workspace.id}
              phx-hook="WindowPickerView"
              data-view={Atom.to_string(@window_picker_view)}
              class={[
                "header-terminal-pickers flex min-w-0 items-center pointer-coarse:hidden",
                if(@window_picker_view == :tabs, do: "flex-1", else: "shrink")
              ]}
            >
              <%= if @window_picker_view == :tabs do %>
                <SessionBar.window_tabs
                  workspace_id={@workspace.id}
                  path_base={@workspace_route}
                  windows={@tmux_window_tabs}
                  topology_version={@tmux_topology_structure_version}
                  mutations_allowed?={@tmux_mutations_enabled?}
                  rename_window_id={@tmux_rename_window_id}
                  class="min-w-0 flex-1"
                />
              <% else %>
                <SessionBar.window_dropdown
                  workspace_id={@workspace.id}
                  path_base={@workspace_route}
                  windows={@tmux_window_tabs}
                  session_id={if @terminal_sid != @default_terminal_sid, do: @terminal_sid}
                  share_session_id={@terminal_sid}
                  topology_version={@tmux_topology_structure_version}
                  mutations_allowed?={@tmux_mutations_enabled?}
                  rename_window_id={@tmux_rename_window_id}
                  selected_preview={
                    TerminalState.selected_preview_pane(
                      @preview_panes,
                      @entered_preview_pane_id,
                      @ui_highlight_pane_id,
                      @tmux_windows,
                      @tmux_active_window_id,
                      @tmux_session
                    )
                  }
                />
              <% end %>
            </div>
            <%!-- Window/pane actions — inline only for what has no
                 direct-manipulation equivalent (splits, zoom). Window cycling
                 stays only in dropdown view, where tabs aren't clickable.
                 Everything else lives in the ⋯ overflow menu + C-b keys. --%>
            <div class="header-p-mid header-p-as-flex shrink-0 items-center gap-1 pointer-coarse:!hidden">
              <%= if @window_picker_view == :dropdown and length(@tmux_window_tabs) > 1 do %>
                <.leader_key_button
                  key="p"
                  phx_click="tmux:cycle_window"
                  phx_value_dir="prev"
                  title="Previous window · Ctrl + B p"
                  aria_label="Previous tmux window"
                >
                  <.icon name="hero-chevron-left" class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key="n"
                  phx_click="tmux:cycle_window"
                  phx_value_dir="next"
                  title="Next window · Ctrl + B n"
                  aria_label="Next tmux window"
                >
                  <.icon name="hero-chevron-right" class="size-3.5" />
                </.leader_key_button>
              <% end %>
              <%= if @terminal_mode in [:raw, :raw_ghostty] do %>
                <span class="mx-0.5 h-4 w-px shrink-0 bg-base-300"></span>
                <%!-- Splits and zoom --%>
                <.leader_key_button
                  key="%"
                  phx_click="split_right"
                  title="Split right · Ctrl + B %"
                  aria_label="Split pane right"
                >
                  <.split_icon direction={:right} class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key={"\""}
                  phx_click="split_down"
                  title="Split down · Ctrl + B &quot;"
                  aria_label="Split pane down"
                >
                  <.split_icon direction={:down} class="size-3.5" />
                </.leader_key_button>
                <.leader_key_button
                  key="z"
                  phx_click="pane:zoom_focused"
                  title={
                    if @window_zoomed?,
                      do: "Unzoom pane · Ctrl + B z",
                      else: "Zoom pane · Ctrl + B z"
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
                <span class="mx-0.5 h-4 w-px shrink-0 bg-base-300 pointer-coarse:hidden"></span>
                <button
                  type="button"
                  phx-click={JS.dispatch("devide:terminal-display-zoom", detail: %{delta: -0.1})}
                  class="inline-flex size-6 shrink-0 items-center justify-center rounded border border-base-300 text-base-content/70 transition hover:bg-base-200 pointer-coarse:hidden"
                  title="Decrease display zoom · Ctrl + scroll"
                  aria-label="Decrease display zoom"
                >
                  <.icon name="hero-magnifying-glass-minus" class="size-3.5" />
                </button>
                <button
                  type="button"
                  phx-click={JS.dispatch("devide:terminal-display-zoom", detail: %{reset: true})}
                  class="inline-flex h-6 shrink-0 items-center justify-center rounded border border-base-300 px-1.5 font-mono text-[10px] leading-none text-base-content/70 transition hover:bg-base-200 pointer-coarse:hidden"
                  title="Reset display zoom"
                  aria-label="Reset display zoom"
                >
                  100%
                </button>
                <button
                  type="button"
                  phx-click={JS.dispatch("devide:terminal-display-zoom", detail: %{delta: 0.1})}
                  class="inline-flex size-6 shrink-0 items-center justify-center rounded border border-base-300 text-base-content/70 transition hover:bg-base-200 pointer-coarse:hidden"
                  title="Increase display zoom · Ctrl + scroll"
                  aria-label="Increase display zoom"
                >
                  <.icon name="hero-magnifying-glass-plus" class="size-3.5" />
                </button>
              <% end %>
            </div>
          <% end %>
          <div class="ml-auto flex shrink-0 items-center gap-0.5 pointer-coarse:gap-0.5">
            <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
              <SessionBar.session_dropdown
                workspace_id={@workspace.id}
                path_base={@workspace_route}
                tabs={@session_tabs}
                workspace_tabs={@workspace_session_tabs}
                active_id={@terminal_sid}
                preview_panes={@preview_panes}
                active_fallback_label={session_kind_label(@active_session_kind)}
                active_fallback_detail={terminal_session_label(@tmux_session, @terminal_sid)}
                mutations_allowed?={@tmux_mutations_enabled?}
                rename_session_id={@tmux_rename_session_id}
                default_sid={@default_terminal_sid}
              />
              <div class="header-p-mid header-p-as-block mx-0.5 h-4 w-px shrink-0 bg-base-300"></div>
            <% end %>
            <button
              :if={@tab == "terminal"}
              id={"leader-prefix-button-" <> @workspace.id}
              type="button"
              data-leader-prefix-button="true"
              class="leader-prefix-button header-p-mid header-p-as-block shrink-0 rounded border border-base-300 bg-base-100 px-1.5 py-0.5 font-mono text-[10px] font-semibold leading-none text-base-content/70 transition hover:border-primary/40 hover:bg-base-200 hover:text-base-content active:scale-[0.98] pointer-coarse:hidden"
              title="tmux prefix key"
              aria-label="tmux prefix key"
              aria-pressed="false"
            >
              C-b
            </button>
            <.header_overflow_menu {header_overflow_attrs(assigns)} />
            <button
              phx-click="terminal:toggle_chrome"
              data-shortcut="Ctrl/Cmd + Shift + F"
              class="inline-flex items-center justify-center rounded border border-base-300 p-1 text-sm text-base-content/80 hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:p-0"
              title="Focus mode. Shortcut: Ctrl/Cmd + Shift + F"
              aria-label="Hide header for a terminal-only view"
            >
              <span class="leading-none pointer-coarse:text-xs" aria-hidden="true">▴</span>
            </button>
          </div>
        </header>
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
            no data-leader-action. Exceptions: the pickers (C-b s / w) stay on
            the dropdown <summary> elements because they need the dropdown UI,
            and window-by-index targets live on the window tabs. --%>
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
            phx-click={
              JS.set_attribute({"open", "open"}, to: "#window-dropdown-#{@workspace.id}")
              |> JS.push("tmux:rename_start")
            }
            phx-value-window-id={@tmux_active_window_id}
          ></button>
          <button
            :if={is_binary(@tmux_session)}
            type="button"
            tabindex="-1"
            data-leader-action="rename-session"
            phx-click={
              JS.set_attribute({"open", "open"}, to: "#session-dropdown-#{@workspace.id}")
              |> JS.push("terminal:rename_session_start")
            }
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
          rename_input={@rename_input}
          delete_confirm={@delete_confirm}
          save_error={@save_error}
          file_error={@file_error}
          node_rename={@node_rename}
          node_delete={@node_delete}
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
        />
        <.live_component
          :if={@tab == "proposals"}
          module={DevIdeWeb.WorkspaceLive.ProposalPanelComponent}
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
      </div>
    </div>
    <.live_component
      module={DevIdeWeb.WorkspaceLive.AuditDrawerComponent}
      id="audit-drawer"
      open={@audit_drawer_open}
      workspace={@workspace}
      current_user={@current_user}
    />
    <.leader_help_overlay />
    """
  end

  defp header_overflow_attrs(assigns) do
    Map.take(assigns, [
      :workspace,
      :workspace_start_error,
      :tab,
      :host_loc,
      :tmux_mutations_enabled?,
      :tmux_window_tabs,
      :terminal_mode,
      :tmux_session,
      :terminal_sid,
      :active_window_pane_count,
      :window_picker_view
    ])
  end

  defp terminal_tab_attrs(assigns) do
    Map.take(assigns, [
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
      :pane_data,
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
      :tmux_window_tabs
    ])
  end

  defp current_share_url(assigns) do
    SessionBar.share_url(
      assigns.workspace.id,
      assigns.terminal_sid,
      assigns[:tmux_active_window_id],
      DevIdeWeb.WorkspaceLive.Show.ViewDeepLink.share_query_opts(assigns)
    )
  end

  defp active_tmux_window_name(assigns) do
    DevIdeWeb.WorkspaceLive.Show.WindowTerminalMode.active_window_name(%{assigns: assigns})
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
