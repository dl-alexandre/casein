defmodule DevIdeWeb.WorkspaceLive.Show.SessionBar do
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

  use DevIdeWeb, :html

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
            class="mt-0.5 max-w-44 truncate font-mono text-[10px] text-primary/80"
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
              class={terminal_tab_class(@active_id == tab.id)}
              title={tab.title}
            >
              <span class="max-w-44 truncate font-medium">{tab.label}</span>
              <span
                :if={tab.detail != ""}
                class="mt-0.5 max-w-44 truncate font-mono text-[10px] text-primary/80"
              >
                {tab.detail}
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
              <span class="max-w-44 truncate font-medium">{tab.label}</span>
              <span
                :if={tab.detail != ""}
                class="mt-0.5 max-w-44 truncate font-mono text-[10px] text-primary/80"
              >
                {tab.detail}
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
              <span class="max-w-44 truncate font-medium">{tab.label}</span>
              <span
                :if={tab.detail != ""}
                class="mt-0.5 max-w-44 truncate font-mono text-[10px] text-primary/80"
              >
                {tab.detail}
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

  defp window_row_name(assigns) do
    ~H"""
    <span class="shrink-0 font-mono text-[10px] text-base-content/45">{@window.index}</span>
    <%= if @picker_label? do %>
      <span data-picker-label class={@name_class}>{@window.display_name}</span>
    <% else %>
      <span class={@name_class}>{@window.display_name}</span>
    <% end %>
    """
  end

  attr :window, :map, required: true
  attr :preview_id, :string, default: nil
  attr :activity_id, :string, default: nil
  attr :show_command?, :boolean, default: false
  attr :preview_aria_hidden?, :boolean, default: false

  defp window_row_indicators(assigns) do
    ~H"""
    <span
      :if={@window.preview?}
      id={@preview_id}
      data-preview-window={@preview_id && "true"}
      data-preview-count={@preview_id && @window.preview_count}
      class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300"
      title={window_preview_tooltip(@window.preview_count, @preview_aria_hidden?)}
      aria-label={
        if(@preview_aria_hidden?, do: nil, else: window_preview_tooltip(@window.preview_count, false))
      }
      aria-hidden={@preview_aria_hidden? || nil}
    >
      <.icon name="hero-globe-alt" class="size-3" />
    </span>
    <span
      id={@activity_id}
      data-activity-state={@activity_id && @window.activity_state}
      class={["size-1.5 shrink-0 rounded-full", @window.activity_class]}
      title={@window.activity_label}
      aria-label={@window.activity_label}
    ></span>
    <span :if={@show_command?} class="shrink-0 font-mono text-[10px] text-base-content/45">
      {@window.command}
    </span>
    """
  end

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
        <%= for window <- @windows do %>
          <div
            id={"tmux-window-" <> window.dom_frag}
            data-ctx-menu="window_tab"
            data-ctx-window-id={window.id}
            data-ctx-href={window_href(@workspace_id, window.id, path_base: @path_base)}
            data-active-window={window.active? || nil}
            class={[
              "group flex min-w-28 max-w-80 flex-1 items-center gap-1 rounded-t border border-b-0 px-2 py-1 text-xs transition-colors",
              if(window.active?,
                do: "border-primary bg-base-100 text-base-content shadow-sm",
                else:
                  "border-base-300 bg-base-200/70 text-base-content/65 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <a
              href={window_href(@workspace_id, window.id, path_base: @path_base)}
              data-window-tab-select
              phx-click="tmux:select_window"
              phx-value-window-id={window.id}
              data-tmux-window-index={window.index}
              class="flex min-w-0 flex-1 items-center gap-1"
              title={"Select tmux window " <> window.full_title}
            >
              <.window_row_name window={window} />
              <.window_row_indicators
                window={window}
                preview_id={"tmux-window-preview-" <> window.dom_frag}
                activity_id={"tmux-window-activity-" <> window.dom_frag}
                show_command?
              />
            </a>
            <%= if @mutations_allowed? do %>
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
                  class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-base-300 hover:text-base-content"
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
                data-confirm="Kill this tmux window and everything running in it?"
                class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-error/10 hover:text-error"
                title="Close tmux window"
                aria-label="Close tmux window"
                disabled={length(@windows) <= 1}
              >
                <.icon name="hero-x-mark" class="size-3.5" />
              </button>
            <% end %>
          </div>
        <% end %>
      </div>
      <%= if @mutations_allowed? do %>
        <button
          type="button"
          phx-click="tmux:new_window"
          class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
          title="New window · Ctrl + B c"
          aria-label="New tmux window"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      <% end %>
    </div>
    """
  end

  attr :workspace_id, :string, required: true
  attr :tree, :list, required: true, doc: "SessionBarVM.workspace_session_tree/4 nodes"
  attr :active_id, :string, default: nil
  attr :default_sid, :string, default: nil
  attr :preview_panes, :map, default: %{}
  attr :path_base, :string, default: nil
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_session_id, :string, default: nil

  attr :class, :any,
    default: nil,
    doc: "layout classes — desktop-only summoned SESSIONS rail"

  def sessions_sidebar(assigns) do
    ~H"""
    <nav
      :if={@tree != []}
      id={"sessions-sidebar-" <> @workspace_id}
      data-sessions-picker-sidebar="true"
      data-shortcut="Ctrl + B, then S"
      phx-hook="SessionsPickerSidebar"
      aria-label="Workspaces and sessions"
      class={[
        "sessions-picker-sidebar leader-key-control flex w-44 shrink-0 flex-col border-r border-base-300/70 bg-base-200/40",
        @class
      ]}
    >
      <div class="shrink-0 border-b border-base-300/70 px-2 py-1 text-[10px] font-semibold uppercase tracking-wide text-base-content/50">
        Sessions
      </div>
      <div
        data-picker-filter
        class="hidden shrink-0 border-b border-base-300/70 px-2 py-1 font-mono text-[10px] text-base-content/60"
      >
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto py-1">
        <%= for node <- @tree do %>
          <%= cond do %>
            <% node.flat_session? -> %>
              <.sessions_sidebar_session_row
                session={node.session}
                workspace_id={@workspace_id}
                current_workspace_id={@workspace_id}
                active_id={@active_id}
                default_sid={@default_sid}
                preview_panes={@preview_panes}
                path_base={@path_base}
                parent_dom_id={nil}
                mutations_allowed?={@mutations_allowed?}
                rename_session_id={@rename_session_id}
              />
            <% node.expanded? -> %>
              <div class="flex flex-col gap-0.5">
                <div class="flex items-center gap-1 px-1">
                  <button
                    type="button"
                    data-picker-item
                    data-picker-section="workspaces"
                    data-picker-sessions-id={node.dom_id}
                    phx-click="sidebar:toggle_workspace"
                    phx-value-workspace-id={node.workspace_id}
                    class={[sidebar_row_class(node.current?), "min-w-0 flex-1"]}
                    title={node.title}
                  >
                    <span class="flex min-w-0 items-center gap-1">
                      <span data-picker-label class="truncate font-medium">{node.label}</span>
                      <span
                        :if={not node.live?}
                        class="size-1.5 shrink-0 rounded-full bg-base-content/25"
                        title="No live tmux sessions"
                      />
                    </span>
                    <span
                      :if={node.detail != ""}
                      class="truncate font-mono text-[10px] text-base-content/50"
                    >
                      {node.detail}
                    </span>
                  </button>
                  <button
                    type="button"
                    tabindex="-1"
                    phx-click="sidebar:toggle_workspace"
                    phx-value-workspace-id={node.workspace_id}
                    class="flex shrink-0 items-center gap-0.5 rounded px-1.5 py-1 font-mono text-[10px] text-base-content/45 hover:bg-base-200"
                    aria-label={"Collapse " <> node.label}
                  >
                    {node.session_count}
                    <span class="flex rotate-90 transition-transform">
                      <.icon name="hero-chevron-right" class="size-3" />
                    </span>
                  </button>
                </div>
                <div id={"sidebar-ws-sessions-" <> node.workspace_id} class="space-y-0.5 pl-3">
                  <%= for session <- node.sessions || [] do %>
                    <.sessions_sidebar_session_row
                      session={session}
                      workspace_id={Map.get(session, :workspace_id, node.workspace_id)}
                      current_workspace_id={@workspace_id}
                      active_id={@active_id}
                      default_sid={@default_sid}
                      preview_panes={@preview_panes}
                      path_base={@path_base}
                      parent_dom_id={node.dom_id}
                      mutations_allowed?={@mutations_allowed?}
                      rename_session_id={@rename_session_id}
                    />
                  <% end %>
                </div>
              </div>
            <% true -> %>
              <div class="flex items-center gap-1 px-1">
                <button
                  type="button"
                  data-picker-item
                  data-picker-section="workspaces"
                  phx-click="sidebar:toggle_workspace"
                  phx-value-workspace-id={node.workspace_id}
                  class={[sidebar_row_class(false), "min-w-0 flex-1"]}
                  title={node.title}
                >
                  <span class="flex min-w-0 items-center gap-1">
                    <span data-picker-label class="truncate font-medium">{node.label}</span>
                    <span
                      :if={not node.live?}
                      class="size-1.5 shrink-0 rounded-full bg-base-content/25"
                      title="No live tmux sessions"
                    />
                  </span>
                  <span
                    :if={node.detail != ""}
                    class="truncate font-mono text-[10px] text-base-content/50"
                  >
                    {node.detail}
                  </span>
                </button>
                <button
                  :if={node.session_count > 0}
                  type="button"
                  tabindex="-1"
                  phx-click="sidebar:toggle_workspace"
                  phx-value-workspace-id={node.workspace_id}
                  class="flex shrink-0 items-center gap-0.5 rounded px-1.5 py-1 font-mono text-[10px] text-base-content/45 hover:bg-base-200"
                  aria-label={"Expand " <> node.label}
                >
                  {node.session_count}
                  <span class="flex transition-transform">
                    <.icon name="hero-chevron-right" class="size-3" />
                  </span>
                </button>
              </div>
          <% end %>
        <% end %>
      </div>
      <button
        type="button"
        phx-click="terminal:refresh_sessions"
        class="shrink-0 border-t border-base-300/70 px-2 py-2 text-xs text-base-content/70 hover:bg-base-200"
        title="Refresh workspaces and sessions"
        aria-label="Refresh workspaces and sessions"
      >
        <span class="inline-flex items-center gap-1">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </span>
      </button>
    </nav>
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
    cross_workspace? = assigns.workspace_id != assigns.current_workspace_id
    session_active? = assigns.active_id == assigns.session.id and not cross_workspace?
    href = Map.get(assigns.session, :href) || sidebar_session_href(assigns.workspace_id, assigns.session.id)

    assigns =
      assigns
      |> assign(:cross_workspace?, cross_workspace?)
      |> assign(:session_active?, session_active?)
      |> assign(:href, href)

    ~H"""
    <div class="flex items-center gap-1 px-1">
      <%= if @cross_workspace? do %>
        <.link
          id={@session.dom_id}
          navigate={@href}
          data-picker-item
          data-picker-section="sessions"
          data-picker-parent={@parent_dom_id}
          class={[sidebar_row_class(false), "min-w-0 flex-1"]}
          title={@session.title}
        >
          <.sessions_sidebar_session_labels session={@session} preview_panes={@preview_panes} default_sid={@default_sid} />
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
          class={[sidebar_row_class(@session_active?), "min-w-0 flex-1"]}
          title={@session.title}
        >
          <.sessions_sidebar_session_labels session={@session} preview_panes={@preview_panes} default_sid={@default_sid} />
        </a>
      <% end %>
      <.copy_link_button
        url={if(@cross_workspace?, do: session_share_url_from_href(@href), else: session_share_url(@workspace_id, @session.id, @path_base))}
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
          <button type="submit" class="rounded p-1 text-primary hover:bg-primary/10" title="Save session name">
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
    ~H"""
    <span class="flex min-w-0 items-center gap-1">
      <span
        :if={@session.id == @default_sid}
        class="flex shrink-0 text-base-content/40"
        title="Home session — your landing shell"
        aria-label="Home session"
      >
        <.icon name="hero-home" class="size-3" />
      </span>
      <span data-picker-label class="truncate font-medium">{@session.label}</span>
      <.preview_badge
        count={preview_pane_count(@session.pane_ids, @preview_panes)}
        id={"sidebar-session-preview-" <> @session.dom_id}
        scope="session"
      />
      <span
        :if={@session.quiet_count > 0}
        data-attention={@session.attention}
        class={quiet_badge_class(@session.attention)}
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
    <span :if={@session.detail != ""} class="truncate font-mono text-[10px] text-base-content/50">
      {@session.detail}
    </span>
    """
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
      data-picker-active={@node.active? || nil}
      data-picker-parent={@parent_dom_id}
      phx-click="tmux:select_window"
      phx-value-window-id={@node.id}
      data-tmux-window-index={@node.index}
      class={@class}
      title={"Select tmux window " <> @node.full_title}
    >
      <span class="flex min-w-0 items-center gap-1.5">
        <.window_row_name
          window={@node}
          picker_label?
          name_class="min-w-0 flex-1 truncate font-medium"
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
      <span class="flex min-w-0 items-center gap-1.5">
        <span class="shrink-0 font-mono text-[10px] text-base-content/45">{@pane.index}</span>
        <span data-picker-label class="min-w-0 truncate font-medium">{@pane.label}</span>
        <span
          :if={@pane.preview?}
          class="inline-flex size-3.5 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300"
          title="Preview pane"
          aria-label="Preview pane"
        >
          <.icon name="hero-globe-alt" class="size-2.5" />
        </span>
        <span
          :if={not @pane.preview?}
          data-activity-state={@pane.activity_state}
          class={["size-1.5 shrink-0 rounded-full", @pane.activity_class]}
          title={@pane.activity_label}
          aria-label={@pane.activity_label}
        />
      </span>
      <span :if={@pane.detail != ""} class="truncate font-mono text-[10px] text-base-content/50">
        {@pane.detail}
      </span>
    </a>
    """
  end

  attr :workspace_id, :string, required: true
  attr :tabs, :list, required: true
  attr :active_id, :string, default: nil
  attr :active_fallback_label, :string, default: "session"
  attr :active_fallback_detail, :string, default: ""

  def session_header_indicator(assigns) do
    ~H"""
    <div
      class="leader-key-control flex shrink-0 items-center gap-1 rounded px-1.5 py-0.5 text-xs pointer-coarse:hidden"
      data-shortcut="Ctrl + B, then S"
      title={
        active_session_picker_title(
          @tabs,
          @active_id,
          @active_fallback_label,
          @active_fallback_detail
        )
      }
    >
      <span
        id={"attention-surface-" <> @workspace_id}
        phx-hook="AttentionSurface"
        class="hidden"
        aria-hidden="true"
      ></span>
      <% summary_label = active_session_label(@tabs, @active_id, @active_fallback_label)

      summary_detail =
        active_session_detail(@tabs, @active_id, @active_fallback_detail) %>
      <span class="max-w-[5rem] truncate font-medium sm:max-w-44">
        <span class="header-p-min-full">{summary_label}</span>
        <span class="header-p-min-short" title={summary_label}>
          {session_picker_short_label(summary_label)}
        </span>
        <span
          :if={summary_detail != "" and summary_detail != summary_label}
          class="header-p-low header-p-as-inline font-mono font-normal text-base-content/50"
        >
          {" · " <> summary_detail}
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
    </div>
    """
  end

  attr :workspace_id, :string, required: true
  attr :tree, :list, required: true, doc: "SessionBarVM.window_tree/2 nodes"
  attr :terminal_sid, :string, default: nil
  attr :topology_version, :integer, default: 0
  attr :mutations_allowed?, :boolean, required: true
  attr :rename_window_id, :string, default: nil
  attr :path_base, :string, default: nil

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
      phx-hook="WindowPickerSidebar"
      aria-label="Tmux windows and panes"
      class={[
        "window-picker-sidebar flex w-44 shrink-0 flex-col border-r border-base-300/70 bg-base-200/40",
        @class
      ]}
    >
      <div
        data-picker-filter
        class="hidden shrink-0 border-b border-base-300/70 px-2 py-1 font-mono text-[10px] text-base-content/60"
      >
      </div>
      <div class="min-h-0 flex-1 overflow-y-auto py-1">
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
            <% node.expanded? -> %>
              <div
                id={"tmux-window-sidebar-" <> node.dom_frag}
                data-ctx-menu="window_tab"
                data-ctx-window-id={node.id}
                class="flex flex-col gap-0.5"
              >
                <div class="flex items-center gap-1 px-1">
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
                    class="flex shrink-0 items-center gap-0.5 rounded px-1.5 py-1 font-mono text-[10px] text-base-content/45 hover:bg-base-200"
                    aria-label={"Collapse panes of " <> node.display_name}
                  >
                    {node.pane_count}
                    <span class="flex rotate-90 transition-transform">
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
                <div id={"sidebar-window-panes-" <> node.dom_frag} class="space-y-0.5 pl-3">
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
            <% true -> %>
              <div
                id={"tmux-window-sidebar-" <> node.dom_frag}
                data-ctx-menu="window_tab"
                data-ctx-window-id={node.id}
                class="flex items-center gap-1 px-1"
              >
                <.window_sidebar_window_link
                  node={node}
                  workspace_id={@workspace_id}
                  terminal_sid={@terminal_sid}
                  path_base={@path_base}
                  parent_dom_id={nil}
                  class={[sidebar_row_class(node.active?), "min-w-0 flex-1"]}
                />
                <button
                  :if={node.pane_count > 1}
                  type="button"
                  tabindex="-1"
                  phx-click="sidebar:toggle_window"
                  phx-value-window-id={node.id}
                  class="flex shrink-0 items-center gap-0.5 rounded px-1.5 py-1 font-mono text-[10px] text-base-content/45 hover:bg-base-200"
                  aria-label={"Expand panes of " <> node.display_name}
                >
                  {node.pane_count}
                  <span class="flex transition-transform">
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
          <% end %>
        <% end %>
      </div>
      <%= if @mutations_allowed? do %>
        <button
          type="button"
          phx-click="tmux:new_window"
          class="shrink-0 border-t border-base-300/70 px-2 py-2 text-xs text-base-content/70 hover:bg-base-200"
          title="New window · Ctrl + B c"
          aria-label="New tmux window"
        >
          <span class="inline-flex items-center gap-1">
            <.icon name="hero-plus" class="size-3.5" /> New window
          </span>
        </button>
      <% end %>
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
      class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300"
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
      "flex w-full flex-col items-start gap-0.5 rounded border border-primary/40 bg-primary/10 px-2 py-1.5 text-left text-xs text-primary"

  defp sidebar_row_class(false),
    do:
      "flex w-full flex-col items-start gap-0.5 rounded px-2 py-1.5 text-left text-xs text-base-content/80 hover:bg-base-200"

  defp sidebar_session_href(workspace_id, session_id)
       when is_binary(workspace_id) and is_binary(session_id) do
    "/workspaces/#{workspace_id}?session=#{URI.encode_www_form(session_id)}"
  end

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
      %{label: label} -> label
      nil -> fallback_label
    end
  end

  defp active_session_detail(tabs, active_id, fallback_detail) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{detail: detail} -> detail
      nil -> fallback_detail
    end
  end

  defp active_session_picker_title(tabs, active_id, fallback_label, fallback_detail) do
    label = active_session_label(tabs, active_id, fallback_label)
    detail = active_session_detail(tabs, active_id, fallback_detail)

    session =
      if detail != "" and detail != label do
        label <> " · " <> detail
      else
        label
      end

    "Active session: " <> session <> ". Shortcut: Ctrl + B, then S opens the sessions sidebar"
  end

  attr :kill_hint, :boolean, default: false

  defp picker_keyboard_hint(assigns) do
    ~H"""
    <div class="border-t border-base-300 px-3 py-1 font-mono text-[10px] text-base-content/45">
      ↑↓ move · o open · l copy link · r rename<%= if @kill_hint do %>
        · & kill
      <% end %>
    </div>
    """
  end

  attr :url, :string, required: true
  attr :label, :string, required: true
  attr :kind, :string, default: "session"
  attr :visible?, :boolean, default: false

  def copy_link_button(assigns) do
    ~H"""
    <button
      type="button"
      tabindex="-1"
      data-copy-session-link={@url}
      data-copy-link-kind={@kind}
      class={[
        "shrink-0 rounded p-1 transition-opacity hover:bg-base-300/60",
        @visible? && "opacity-100",
        !@visible? && "opacity-0 group-hover:opacity-100"
      ]}
      title={"Copy link to " <> @label}
      aria-label={"Copy link to " <> @label}
    >
      <.icon name="hero-link" class="size-3" />
    </button>
    """
  end

  @doc "Absolute share URL for the workspace session, optionally pinned to a window/pane/zoom."
  @spec share_url(String.t(), String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def share_url(workspace_id, session_id, window_id \\ nil, opts \\ [])

  def share_url(workspace_id, session_id, window_id, opts)
      when is_binary(workspace_id) and is_binary(session_id) and session_id != "" and
             is_binary(window_id) and window_id != "" do
    DevIdeWeb.Endpoint.url() <> session_window_href(workspace_id, session_id, window_id, opts)
  end

  def share_url(workspace_id, session_id, _window_id, opts)
      when is_binary(workspace_id) and is_binary(session_id) and session_id != "" do
    DevIdeWeb.Endpoint.url() <> session_href(workspace_id, session_id, opts[:path_base])
  end

  def share_url(_workspace_id, _session_id, _window_id, _opts), do: nil

  defp workspace_href(workspace_id, path_base), do: path_base(workspace_id, path_base)

  defp session_href(workspace_id, session_id, path_base),
    do: query_href(path_base(workspace_id, path_base), session: session_id)

  defp session_share_url(workspace_id, session_id, path_base),
    do: share_url(workspace_id, session_id, nil, path_base: path_base)

  defp session_share_url_from_href(href) when is_binary(href) and href != "" do
    DevIdeWeb.Endpoint.url() <> href
  end

  defp window_share_url(workspace_id, session_id, window_id, path_base),
    do: share_url(workspace_id, session_id, window_id, path_base: path_base)

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

  defp session_window_href(workspace_id, session_id, window_id, opts \\ []) do
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

  defp dropdown_item_class(false),
    do:
      "group flex w-full items-center gap-1 px-3 py-1.5 text-left text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"

  defp dropdown_row_class(true),
    do: "group flex w-full items-center px-3 py-1.5 text-xs bg-primary/5 text-primary"

  defp dropdown_row_class(false),
    do:
      "group flex w-full items-center px-3 py-1.5 text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"

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
    if unseen_quiet_window_count(tabs) > 0, do: "unseen", else: "inline"
  end

  defp quiet_badge_class("unseen") do
    "size-2 shrink-0 rounded-full bg-fuchsia-400 shadow-[0_0_0_4px_rgba(217,70,239,0.24)] ring-1 ring-fuchsia-200/80"
  end

  defp quiet_badge_class(_attention) do
    "size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
  end

  defp quiet_badge_label(_quiet_count, 1), do: "1 unseen quiet agent window"

  defp quiet_badge_label(_quiet_count, unseen_count) when unseen_count > 1,
    do: "#{unseen_count} unseen quiet agent windows"

  defp quiet_badge_label(1, _unseen_count), do: "1 quiet agent window"
  defp quiet_badge_label(count, _unseen_count), do: "#{count} quiet agent windows"

  defp window_quiet_badge_label(%{unseen_quiet?: true}), do: "Unseen quiet agent window"

  defp window_quiet_badge_label(window), do: window.quiet_label
end
