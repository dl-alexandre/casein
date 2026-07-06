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
  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

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
              <span class="shrink-0 font-mono text-[10px] text-base-content/45">{window.index}</span>
              <span class="min-w-0 truncate font-medium">{window.display_name}</span>
              <span
                :if={window.preview?}
                id={"tmux-window-preview-" <> window.dom_frag}
                data-preview-window="true"
                data-preview-count={window.preview_count}
                class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300"
                title={"Preview pane open in this window (" <> to_string(window.preview_count) <> ")"}
                aria-label={"Preview pane open in this window (" <> to_string(window.preview_count) <> ")"}
              >
                <.icon name="hero-globe-alt" class="size-3" />
              </span>
              <span
                id={"tmux-window-activity-" <> window.dom_frag}
                data-activity-state={window.activity_state}
                class={[
                  "size-1.5 shrink-0 rounded-full",
                  window.activity_class
                ]}
                title={window.activity_label}
                aria-label={window.activity_label}
              ></span>
              <span class="shrink-0 font-mono text-[10px] text-base-content/45">{window.command}</span>
            </a>
            <%= if @mutations_allowed? do %>
              <%= if @rename_window_id == window.id do %>
                <.form
                  for={to_form(%{"id" => window.id, "name" => window.name}, as: :window)}
                  id={"tmux-rename-form-" <> window.dom_frag}
                  phx-submit="tmux:rename_window"
                  class="ml-1 flex items-center gap-1"
                >
                  <input type="hidden" name="window[id]" value={window.id} />
                  <input
                    type="text"
                    id={"tmux-rename-input-" <> window.dom_frag}
                    name="window[name]"
                    value={window.name}
                    phx-hook="RenameInput"
                    phx-keydown="tmux:rename_cancel"
                    phx-key="Escape"
                    autocomplete="off"
                    class="h-6 w-28 rounded border border-base-300 bg-base-100 px-2 py-0 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
                  />
                  <button
                    type="submit"
                    class="rounded p-1 text-primary hover:bg-primary/10"
                    title="Save window name"
                    aria-label="Save window name"
                  >
                    <.icon name="hero-check" class="size-3.5" />
                  </button>
                  <button
                    type="button"
                    phx-click="tmux:rename_cancel"
                    class="rounded p-1 text-base-content/45 hover:bg-base-200 hover:text-base-content"
                    title="Cancel rename"
                    aria-label="Cancel rename"
                  >
                    <.icon name="hero-x-mark" class="size-3.5" />
                  </button>
                </.form>
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

  # ---------------------------------------------------------------------------
  # Dropdown variants (single-bar chrome)
  # ---------------------------------------------------------------------------

  attr :workspace_id, :string, required: true
  attr :tabs, :list, required: true, doc: "SessionBarVM.session_tabs/1 view-models"
  attr :workspace_tabs, :list, default: [], doc: "SessionBarVM.workspace_session_tabs/2 links"
  attr :active_id, :string, default: nil, doc: "current terminal_sid"
  attr :preview_panes, :map, default: %{}, doc: "pane_id => preview registration (live registry)"
  attr :active_fallback_label, :string, default: "session"
  attr :active_fallback_detail, :string, default: ""
  attr :mutations_allowed?, :boolean, default: false
  attr :rename_session_id, :string, default: nil, doc: "session id currently in rename mode"
  attr :path_base, :string, default: nil

  attr :default_sid, :string,
    default: nil,
    doc: "the viewer's landing session id — rendered as a normal row marked \"home\""

  def session_dropdown(assigns) do
    ~H"""
    <details
      class="leader-key-control relative shrink-0"
      id={"session-dropdown-" <> @workspace_id}
      data-shortcut="Ctrl + B, then S"
      phx-hook="SessionPicker"
    >
      <span
        id={"attention-surface-" <> @workspace_id}
        phx-hook="AttentionSurface"
        class="hidden"
        aria-hidden="true"
      ></span>
      <summary
        data-leader-action="session-picker"
        phx-click={JS.push("terminal:refresh_sessions") |> JS.push("tmux:refresh_topology")}
        title={
          active_session_picker_title(
            @tabs,
            @active_id,
            @active_fallback_label,
            @active_fallback_detail
          )
        }
        class="flex cursor-pointer list-none select-none items-center gap-1 rounded px-1.5 py-0.5 text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden"
      >
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
        <span class="text-[10px] text-base-content/40">▾</span>
      </summary>
      <div class="absolute top-full right-0 z-50 mt-0.5 min-w-52 max-w-[90vw] rounded border border-base-300 bg-base-100 py-1 shadow-lg">
        <%!-- Type-to-filter readout — populated client-side by SessionPicker --%>
        <div
          data-picker-filter
          class="hidden border-b border-base-300 px-3 py-1 font-mono text-[10px] text-base-content/60"
        >
        </div>
        <%= for tab <- @tabs do %>
          <div
            id={if(tab.id == @default_sid, do: "terminal-session-shell-" <> @workspace_id)}
            data-picker-active={(tab.id == @default_sid and @active_id == tab.id) || nil}
            class={dropdown_row_class(@active_id == tab.id)}
          >
            <a
              id={tab.dom_id}
              href={session_href(@workspace_id, tab.id, @path_base)}
              data-picker-item
              data-picker-active={@active_id == tab.id || nil}
              data-picker-windows-id={tab.window_count > 0 && tab.dom_id}
              phx-click={
                JS.push("attach_terminal_session")
                |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
              }
              phx-value-session-id={tab.id}
              phx-value-kind={Atom.to_string(tab.kind)}
              phx-value-tmux-session={tab.tmux_session}
              class={[
                "flex min-w-0 flex-1 flex-col items-start text-left",
                @active_id == tab.id && "text-primary"
              ]}
              title={tab.title}
            >
              <span class="flex w-full min-w-0 items-center gap-1.5">
                <span
                  :if={tab.id == @default_sid}
                  class="flex shrink-0 text-base-content/40"
                  title="Home session — your landing shell"
                  aria-label="Home session"
                >
                  <.icon name="hero-home" class="size-3" />
                </span>
                <span data-picker-label class="truncate font-medium">{tab.label}</span>
                <.preview_badge
                  count={preview_pane_count(tab.pane_ids, @preview_panes)}
                  id={"session-preview-" <> tab.dom_id}
                  scope="session"
                />
                <span
                  :if={tab.quiet_count > 0}
                  id={"session-quiet-" <> tab.dom_id}
                  data-attention={tab.attention}
                  class={quiet_badge_class(tab.attention)}
                  title={quiet_badge_label(tab.quiet_count, tab.unseen_quiet_count)}
                  aria-label={quiet_badge_label(tab.quiet_count, tab.unseen_quiet_count)}
                ></span>
                <span
                  :if={tab.quiet_count == 0 and tab.activity_state != :idle}
                  id={"session-activity-" <> tab.dom_id}
                  data-activity-state={tab.activity_state}
                  class={["size-1.5 shrink-0 rounded-full", tab.activity_class]}
                  title={tab.activity_label}
                  aria-label={tab.activity_label}
                ></span>
              </span>
              <span
                :if={tab.detail != ""}
                data-picker-label
                class="truncate font-mono text-[10px] text-base-content/50"
              >
                {tab.detail}
              </span>
            </a>
            <.copy_link_button
              url={session_share_url(@workspace_id, tab.id, @path_base)}
              label={tab.label}
            />
            <a
              href={session_href(@workspace_id, tab.id, @path_base)}
              target="_blank"
              rel="noreferrer"
              tabindex="-1"
              class="shrink-0 rounded p-1 opacity-0 transition-opacity group-hover:opacity-100 hover:bg-base-300/60"
              title="Open in new tab"
              aria-label={"Open " <> tab.label <> " in new tab"}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </a>
            <button
              :if={tab.window_count > 0}
              id={"session-windows-toggle-" <> tab.dom_id}
              type="button"
              tabindex="-1"
              phx-click={
                JS.toggle(to: "#session-windows-" <> tab.dom_id, display: "block")
                |> JS.toggle_class("rotate-90", to: "#session-windows-chevron-" <> tab.dom_id)
              }
              class="ml-2 flex shrink-0 items-center gap-0.5 rounded px-1 py-0.5 font-mono text-[10px] text-base-content/45 hover:bg-base-300/60 hover:text-base-content"
              title={"#{tab.window_count} window#{if tab.window_count == 1, do: "", else: "s"}"}
              aria-label={"Toggle windows of " <> tab.label}
            >
              {tab.window_count}
              <span
                id={"session-windows-chevron-" <> tab.dom_id}
                class="flex transition-transform"
              >
                <.icon name="hero-chevron-right" class="size-3" />
              </span>
            </button>
            <%= if @mutations_allowed? and is_binary(tab.tmux_session) and tab.tmux_session != "" do %>
              <%= if @rename_session_id == tab.id do %>
                <.form
                  for={to_form(%{}, as: :session)}
                  id={"session-rename-form-" <> tab.dom_id}
                  phx-submit="terminal:rename_session"
                  class="ml-1 flex items-center gap-1"
                >
                  <input type="hidden" name="session[id]" value={tab.id} />
                  <input type="hidden" name="session[tmux_session]" value={tab.tmux_session} />
                  <input
                    type="text"
                    id={"session-rename-input-" <> tab.dom_id}
                    name="session[name]"
                    value={tab.label}
                    phx-hook="RenameInput"
                    phx-keydown="terminal:rename_session_cancel"
                    phx-key="Escape"
                    autocomplete="off"
                    class="h-6 w-24 rounded border border-base-300 bg-base-100 px-2 py-0 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
                  />
                  <button
                    type="submit"
                    phx-click={JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")}
                    class="rounded p-1 text-primary hover:bg-primary/10"
                    title="Save session name"
                  >
                    <.icon name="hero-check" class="size-3" />
                  </button>
                  <button
                    type="button"
                    phx-click={
                      JS.push("terminal:rename_session_cancel")
                      |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
                    }
                    class="rounded p-1 text-base-content/45 hover:bg-base-200"
                    title="Cancel rename"
                  >
                    <.icon name="hero-x-mark" class="size-3" />
                  </button>
                </.form>
              <% else %>
                <button
                  type="button"
                  phx-click="terminal:rename_session_start"
                  phx-value-session-id={tab.id}
                  class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-base-300 hover:text-base-content"
                  title="Rename tmux session"
                  aria-label="Rename tmux session"
                >
                  <.icon name="hero-pencil-square" class="size-3" />
                </button>
              <% end %>
              <button
                :if={tab.id != @default_sid}
                type="button"
                phx-click={
                  JS.push("terminal:kill_session")
                  |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
                }
                phx-value-session-id={tab.id}
                phx-value-tmux-session={tab.tmux_session}
                data-confirm="Kill this tmux session and everything running in it?"
                class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-error/10 hover:text-error"
                title="Close tmux session"
                aria-label="Close tmux session"
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            <% end %>
          </div>
          <div :if={tab.windows != []} id={"session-windows-" <> tab.dom_id} class="hidden">
            <%= for window <- tab.windows do %>
              <div class="group flex w-full items-center gap-0.5 py-1 pr-3 pl-7 text-xs text-base-content/60 hover:bg-base-200 hover:text-base-content">
                <a
                  href={session_window_href(@workspace_id, tab.id, window.id, path_base: @path_base)}
                  data-picker-item
                  data-picker-parent={tab.dom_id}
                  phx-click={
                    JS.push("attach_terminal_session")
                    |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
                  }
                  phx-value-session-id={tab.id}
                  phx-value-kind={Atom.to_string(tab.kind)}
                  phx-value-tmux-session={tab.tmux_session}
                  phx-value-window-id={window.id}
                  class="flex min-w-0 flex-1 items-center gap-1 text-left"
                  title={"Attach " <> tab.label <> " on window " <> window.display_name}
                >
                  <span class="font-mono text-[10px] text-base-content/40">{window.index}</span>
                  <span data-picker-label class="max-w-36 truncate">{window.display_name}</span>
                  <.preview_badge
                    count={preview_pane_count(window.pane_ids, @preview_panes)}
                    id={"session-window-preview-" <> tab.dom_id <> "-" <> to_string(window.index)}
                    scope="window"
                  />
                  <span
                    :if={window.active?}
                    class="size-1.5 shrink-0 rounded-full bg-primary/70"
                    title="Active window"
                  ></span>
                  <span
                    :if={window.quiet?}
                    data-quiet="true"
                    data-attention={window.attention}
                    class={quiet_badge_class(window.attention)}
                    title={window_quiet_badge_label(window)}
                    aria-label={window_quiet_badge_label(window)}
                  ></span>
                  <span
                    :if={not window.active? and not window.quiet? and window.activity_state != :idle}
                    data-activity-state={window.activity_state}
                    class={["size-1.5 shrink-0 rounded-full", window.activity_class]}
                    title={window.activity_label}
                    aria-label={window.activity_label}
                  ></span>
                </a>
                <.copy_link_button
                  url={window_share_url(@workspace_id, tab.id, window.id, @path_base)}
                  label={tab.label <> " · " <> window.name}
                  kind="window"
                />
                <a
                  href={session_window_href(@workspace_id, tab.id, window.id, path_base: @path_base)}
                  target="_blank"
                  rel="noreferrer"
                  tabindex="-1"
                  class="shrink-0 rounded p-1 opacity-0 transition-opacity group-hover:opacity-100 hover:bg-base-300/60"
                  title="Open in new tab"
                  aria-label={"Open " <> tab.label <> " on window " <> window.name <> " in new tab"}
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                </a>
              </div>
            <% end %>
          </div>
        <% end %>
        <%= for tab <- @workspace_tabs do %>
          <div class={dropdown_row_class(false)}>
            <%= if tab.href do %>
              <.link
                id={tab.dom_id}
                navigate={tab.href}
                data-picker-item
                data-picker-windows-id={tab.window_count > 0 && tab.dom_id}
                class="flex min-w-0 flex-1 flex-col items-start text-left"
                title={tab.title}
              >
                <span class="flex w-full min-w-0 items-center gap-1.5">
                  <span data-picker-label class="truncate font-medium">{tab.label}</span>
                  <.preview_badge
                    count={tab.preview_count}
                    id={"session-preview-" <> tab.dom_id}
                    scope="session"
                  />
                  <span
                    :if={tab.quiet_count > 0}
                    id={"session-quiet-" <> tab.dom_id}
                    data-attention={tab.attention}
                    class={quiet_badge_class(tab.attention)}
                    title={quiet_badge_label(tab.quiet_count, tab.unseen_quiet_count)}
                    aria-label={quiet_badge_label(tab.quiet_count, tab.unseen_quiet_count)}
                  ></span>
                  <span
                    :if={tab.quiet_count == 0 and tab.activity_state != :idle}
                    id={"session-activity-" <> tab.dom_id}
                    data-activity-state={tab.activity_state}
                    class={["size-1.5 shrink-0 rounded-full", tab.activity_class]}
                    title={tab.activity_label}
                    aria-label={tab.activity_label}
                  ></span>
                </span>
                <span
                  :if={tab.detail != ""}
                  data-picker-label
                  class="truncate font-mono text-[10px] text-base-content/50"
                >
                  {tab.detail}
                </span>
              </.link>
              <.copy_link_button url={session_share_url_from_href(tab.href)} label={tab.label} />
              <a
                href={tab.href}
                target="_blank"
                rel="noreferrer"
                tabindex="-1"
                class="shrink-0 rounded p-1 opacity-0 transition-opacity group-hover:opacity-100 hover:bg-base-300/60"
                title="Open in new tab"
                aria-label={"Open " <> tab.label <> " in new tab"}
              >
                <.icon name="hero-arrow-top-right-on-square" class="size-3" />
              </a>
            <% else %>
              <button
                id={tab.dom_id}
                type="button"
                data-picker-item
                class={[
                  dropdown_item_class(false),
                  "flex min-w-0 flex-1 flex-col items-start opacity-50 cursor-default"
                ]}
                title={tab.title}
                disabled
              >
                <span data-picker-label class="truncate font-medium">{tab.label}</span>
                <span
                  :if={tab.detail != ""}
                  data-picker-label
                  class="truncate font-mono text-[10px] text-base-content/50"
                >
                  {tab.detail}
                </span>
              </button>
            <% end %>
            <button
              :if={tab.window_count > 0}
              id={"session-windows-toggle-" <> tab.dom_id}
              type="button"
              tabindex="-1"
              phx-click={
                JS.toggle(to: "#session-windows-" <> tab.dom_id, display: "block")
                |> JS.toggle_class("rotate-90", to: "#session-windows-chevron-" <> tab.dom_id)
              }
              class="ml-2 flex shrink-0 items-center gap-0.5 rounded px-1 py-0.5 font-mono text-[10px] text-base-content/45 hover:bg-base-300/60 hover:text-base-content"
              title={"#{tab.window_count} window#{if tab.window_count == 1, do: "", else: "s"}"}
              aria-label={"Toggle windows of " <> tab.label}
            >
              {tab.window_count}
              <span
                id={"session-windows-chevron-" <> tab.dom_id}
                class="flex transition-transform"
              >
                <.icon name="hero-chevron-right" class="size-3" />
              </span>
            </button>
          </div>
          <div :if={tab.windows != []} id={"session-windows-" <> tab.dom_id} class="hidden">
            <%= for window <- tab.windows do %>
              <.link
                :if={tab.href}
                navigate={session_window_href(tab.workspace_id, tab.session_id, window.id)}
                data-picker-item
                data-picker-parent={tab.dom_id}
                class="group flex w-full items-center gap-1 py-1 pr-3 pl-7 text-left text-xs text-base-content/60 hover:bg-base-200 hover:text-base-content"
                title={"Open " <> tab.label <> " on window " <> window.display_name}
              >
                <span class="font-mono text-[10px] text-base-content/40">{window.index}</span>
                <span data-picker-label class="max-w-36 truncate">{window.display_name}</span>
                <.preview_badge
                  count={window.preview_count}
                  id={"session-window-preview-" <> tab.dom_id <> "-" <> to_string(window.index)}
                  scope="window"
                />
                <span
                  :if={window.active?}
                  class="size-1.5 shrink-0 rounded-full bg-primary/70"
                  title="Active window"
                ></span>
                <span
                  :if={window.quiet?}
                  data-quiet="true"
                  data-attention={window.attention}
                  class={quiet_badge_class(window.attention)}
                  title={window_quiet_badge_label(window)}
                  aria-label={window_quiet_badge_label(window)}
                ></span>
                <span
                  :if={not window.active? and not window.quiet? and window.activity_state != :idle}
                  data-activity-state={window.activity_state}
                  class={["size-1.5 shrink-0 rounded-full", window.activity_class]}
                  title={window.activity_label}
                  aria-label={window.activity_label}
                ></span>
              </.link>
            <% end %>
          </div>
        <% end %>
        <div class="mt-1 border-t border-base-300 px-2 pt-1">
          <button
            type="button"
            data-picker-item
            phx-click={
              JS.push("terminal:refresh_sessions")
              |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
            }
            class="flex w-full items-center gap-1 rounded px-1 py-0.5 text-[10px] text-base-content/50 hover:bg-base-200 hover:text-base-content"
          >
            ↻ refresh
          </button>
        </div>
        <.picker_keyboard_hint />
        <%!-- choose-tree style preview of the focused entry — filled client-side --%>
        <pre
          data-picker-preview
          class="mt-1 hidden max-h-44 w-80 overflow-hidden border-t border-base-300 px-2 pt-1 pb-1 font-mono text-[9px] leading-snug whitespace-pre text-base-content/70"
        ></pre>
      </div>
    </details>
    """
  end

  attr :workspace_id, :string, required: true
  attr :windows, :list, required: true, doc: "SessionBarVM.window_tabs/1 view-models"

  attr :session_id, :string,
    default: nil,
    doc: "active non-default session to preserve in window links"

  attr :share_session_id, :string,
    default: nil,
    doc: "attached session sid for shareable window copy/open links"

  attr :topology_version, :integer, default: 0
  attr :mutations_allowed?, :boolean, required: true
  attr :rename_window_id, :string, default: nil
  attr :selected_preview, :map, default: nil, doc: "selected preview pane registration"
  attr :path_base, :string, default: nil

  def window_dropdown(assigns) do
    ~H"""
    <div
      data-shortcut="Ctrl + B, then W"
      class={[
        "leader-key-control flex min-w-0 shrink-0 items-center overflow-visible rounded border border-base-300 bg-base-100 text-xs shadow-sm",
        is_map(@selected_preview) && "border-sky-500/30 bg-sky-500/5"
      ]}
    >
      <details
        class="relative min-w-0 shrink"
        id={"window-dropdown-" <> @workspace_id}
        data-version={@topology_version}
        data-shortcut="Ctrl + B, then W"
        data-picker-hop-left={"#session-dropdown-" <> @workspace_id}
        phx-hook="SessionPicker"
      >
        <summary
          data-leader-action="window-picker"
          phx-click="tmux:refresh_topology"
          title="Pick a window or pane. Shortcut: Ctrl + B, then W"
          class="flex min-w-0 cursor-pointer list-none select-none items-center gap-1 rounded-l px-1.5 py-0.5 hover:bg-base-200 [&::-webkit-details-marker]:hidden"
        >
          <span class="max-w-[4rem] truncate font-medium sm:max-w-28">
            {active_window_label(@windows)}
          </span>
          <%= if is_map(@selected_preview) do %>
            <span class="h-4 w-px shrink-0 bg-sky-500/25"></span>
            <span class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300">
              <.icon name="hero-globe-alt" class="size-3" />
            </span>
            <span
              data-preview-pane-id={@selected_preview.pane_id}
              class="min-w-0 max-w-36 truncate font-medium text-sky-700 sm:max-w-44 dark:text-sky-200"
            >
              {preview_display_label(@selected_preview)}
            </span>
            <span
              :if={preview_detail(@selected_preview) != ""}
              class="header-p-low header-p-as-inline max-w-32 truncate font-mono text-[10px] text-sky-700/65 dark:text-sky-200/65"
            >
              {preview_detail(@selected_preview)}
            </span>
          <% end %>
          <span class="text-[10px] text-base-content/40">▾</span>
        </summary>
        <div class="absolute top-full left-0 z-50 mt-0.5 min-w-64 max-w-[90vw] rounded border border-base-300 bg-base-100 py-1 shadow-lg">
          <%!-- Type-to-filter readout — populated client-side by SessionPicker --%>
          <div
            data-picker-filter
            class="hidden border-b border-base-300 px-3 py-1 font-mono text-[10px] text-base-content/60"
          >
          </div>
          <%= for window <- @windows do %>
            <div
              id={"tmux-window-" <> window.dom_frag}
              class={dropdown_row_class(window.active?)}
            >
              <a
                href={window_href(@workspace_id, @session_id, window.id, path_base: @path_base)}
                data-picker-item
                data-picker-active={window.active? || nil}
                data-picker-panes-id={window.pane_count > 0 && "window-panes-" <> window.dom_frag}
                phx-click={
                  JS.push("tmux:select_window")
                  |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                }
                phx-value-window-id={window.id}
                data-tmux-window-index={window.index}
                class="relative flex min-w-0 flex-1 items-center gap-1"
                title={"Select tmux window " <> window.full_title}
              >
                <span class="font-mono text-[10px] text-base-content/40">{window.index}</span>
                <span data-picker-label class="max-w-32 truncate font-medium">{window.display_name}</span>
                <span
                  :if={window.preview?}
                  id={"tmux-window-preview-" <> window.dom_frag}
                  data-preview-window="true"
                  data-preview-count={window.preview_count}
                  class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300"
                  title={"Preview pane open in this window (" <> to_string(window.preview_count) <> ")"}
                  aria-label={"Preview pane open in this window (" <> to_string(window.preview_count) <> ")"}
                >
                  <.icon name="hero-globe-alt" class="size-3" />
                </span>
                <span
                  :if={window.quiet?}
                  id={"tmux-window-quiet-" <> window.dom_frag}
                  data-quiet="true"
                  data-attention={window.attention}
                  class={quiet_badge_class(window.attention)}
                  title={window_quiet_badge_label(window)}
                  aria-label={window_quiet_badge_label(window)}
                ></span>
                <span
                  :if={not window.quiet?}
                  id={"tmux-window-activity-" <> window.dom_frag}
                  data-activity-state={window.activity_state}
                  class={["size-1.5 shrink-0 rounded-full", window.activity_class]}
                  title={window.activity_label}
                  aria-label={window.activity_label}
                ></span>
                <span data-picker-label class="font-mono text-[10px] text-base-content/40">
                  {window.command}
                </span>
              </a>
              <.copy_link_button
                url={window_share_url(@workspace_id, @share_session_id, window.id, @path_base)}
                label={window.name}
                kind="window"
              />
              <button
                :if={window.pane_count > 0}
                id={"window-panes-toggle-" <> window.dom_frag}
                type="button"
                tabindex="-1"
                phx-click={
                  JS.toggle(to: "#window-panes-" <> window.dom_frag, display: "block")
                  |> JS.toggle_class("rotate-90", to: "#window-panes-chevron-" <> window.dom_frag)
                }
                class="ml-1 flex shrink-0 items-center gap-0.5 rounded px-1 py-0.5 font-mono text-[10px] text-base-content/45 hover:bg-base-300/60 hover:text-base-content"
                title={"#{window.pane_count} pane#{if window.pane_count == 1, do: "", else: "s"}"}
                aria-label={"Toggle panes of " <> window.name}
              >
                {window.pane_count}
                <span
                  id={"window-panes-chevron-" <> window.dom_frag}
                  class="flex transition-transform"
                >
                  <.icon name="hero-chevron-right" class="size-3" />
                </span>
              </button>
              <%= if @mutations_allowed? do %>
                <%= if @rename_window_id == window.id do %>
                  <.form
                    for={to_form(%{"id" => window.id, "name" => window.name}, as: :window)}
                    id={"tmux-rename-form-" <> window.dom_frag}
                    phx-submit="tmux:rename_window"
                    class="ml-1 flex items-center gap-1"
                  >
                    <input type="hidden" name="window[id]" value={window.id} />
                    <input
                      type="text"
                      id={"tmux-rename-dropdown-input-" <> window.dom_frag}
                      name="window[name]"
                      value={window.name}
                      phx-hook="RenameInput"
                      phx-keydown="tmux:rename_cancel"
                      phx-key="Escape"
                      autocomplete="off"
                      class="h-6 w-24 rounded border border-base-300 bg-base-100 px-2 py-0 text-xs text-base-content outline-none focus:border-primary focus:ring-1 focus:ring-primary"
                    />
                    <button
                      type="submit"
                      phx-click={JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")}
                      class="rounded p-1 text-primary hover:bg-primary/10"
                      title="Save window name"
                    >
                      <.icon name="hero-check" class="size-3" />
                    </button>
                    <button
                      type="button"
                      phx-click={
                        JS.push("tmux:rename_cancel")
                        |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                      }
                      class="rounded p-1 text-base-content/45 hover:bg-base-200"
                      title="Cancel rename"
                    >
                      <.icon name="hero-x-mark" class="size-3" />
                    </button>
                  </.form>
                <% else %>
                  <button
                    type="button"
                    phx-click="tmux:rename_start"
                    phx-value-window-id={window.id}
                    class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-base-300 hover:text-base-content"
                    title="Rename tmux window"
                  >
                    <.icon name="hero-pencil-square" class="size-3" />
                  </button>
                <% end %>
                <button
                  type="button"
                  phx-click={
                    JS.push("tmux:kill_window")
                    |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                  }
                  phx-value-window-id={window.id}
                  data-confirm="Kill this tmux window and everything running in it?"
                  data-picker-window-kill
                  class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-error/10 hover:text-error"
                  title="Close tmux window"
                  disabled={length(@windows) <= 1}
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              <% end %>
            </div>
            <div
              :if={window.panes != []}
              id={"window-panes-" <> window.dom_frag}
              class="hidden border-l border-base-300/80 ml-3"
            >
              <%= for pane <- window.panes do %>
                <a
                  href={pane_href(@workspace_id, @session_id, window.id, pane.id, @path_base)}
                  id={"window-pane-" <> pane.dom_frag}
                  data-picker-item
                  data-picker-parent={"window-panes-" <> window.dom_frag}
                  data-picker-active={pane.active? || nil}
                  phx-click={
                    JS.push("tmux:select_pane",
                      value: %{"pane-id" => pane.id, "window-id" => window.id}
                    )
                    |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                  }
                  class={[
                    "group flex w-full items-center gap-1.5 py-1 pr-3 pl-4 text-left text-xs",
                    if(pane.active?,
                      do: "bg-primary/5 text-primary",
                      else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                    )
                  ]}
                  title={pane.title}
                >
                  <span class="-ml-4 w-3 shrink-0 border-t border-base-300/80"></span>
                  <%= if pane.preview? do %>
                    <%= if pane.favicon_url do %>
                      <img
                        src={pane.favicon_url}
                        alt=""
                        class="size-4 shrink-0 rounded-sm bg-base-200 object-contain ring-1 ring-base-300/60"
                        loading="lazy"
                        decoding="async"
                      />
                    <% else %>
                      <span class="inline-flex size-4 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 ring-1 ring-sky-500/30 dark:text-sky-300">
                        <.icon name="hero-globe-alt" class="size-3" />
                      </span>
                    <% end %>
                  <% else %>
                    <span class="font-mono text-[10px] text-base-content/40">{pane.index}</span>
                  <% end %>
                  <span class="flex min-w-0 flex-1 flex-col items-start">
                    <span class="flex max-w-44 items-center gap-1 truncate font-medium">
                      <span
                        :if={pane.agent_label?}
                        class="inline-flex size-3.5 shrink-0 items-center justify-center rounded-full bg-violet-500/15 text-violet-600 ring-1 ring-violet-500/25 dark:text-violet-300"
                        title={pane.agent_label_title}
                        aria-label="Agent conversation label"
                      >
                        <.icon name="hero-cpu-chip" class="size-2.5" />
                      </span>
                      <span
                        :if={pane.beside_agent_preview?}
                        class="inline-flex size-3.5 shrink-0 items-center justify-center rounded-full bg-emerald-500/15 text-emerald-600 ring-1 ring-emerald-500/25 dark:text-emerald-300"
                        title={pane.beside_agent_preview_title}
                        aria-label="Preview opened beside agent"
                      >
                        <.icon name="hero-window" class="size-2.5" />
                      </span>
                      <span data-picker-label class="truncate">{pane.label}</span>
                    </span>
                    <span
                      :if={pane.detail != ""}
                      data-picker-label
                      class="max-w-44 truncate font-mono text-[10px] text-base-content/50"
                    >
                      {pane.detail}
                    </span>
                  </span>
                  <span
                    :if={pane.activity_state != :idle}
                    data-activity-state={pane.activity_state}
                    class={["size-1.5 shrink-0 rounded-full", pane.activity_class]}
                    title={pane.activity_label}
                    aria-label={pane.activity_label}
                  ></span>
                </a>
              <% end %>
            </div>
          <% end %>
          <.picker_keyboard_hint kill_hint={@mutations_allowed? and length(@windows) > 1} />
          <div class="mt-1 flex items-center gap-0.5 border-t border-base-300 px-2 pt-1">
            <%= if @mutations_allowed? do %>
              <button
                type="button"
                phx-click={
                  JS.push("palette:templates")
                  |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                }
                class="rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content"
                title="Apply session template"
              >
                <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
              </button>
              <button
                type="button"
                phx-click={
                  JS.push("tmux:open_template_library")
                  |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                }
                class="rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content"
                title="Template library"
              >
                <.icon name="hero-book-open" class="size-3.5" />
              </button>
              <button
                type="button"
                phx-click={
                  JS.push("tmux:new_window")
                  |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                }
                class="rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content"
                title="New window · Ctrl + B c"
              >
                <.icon name="hero-plus" class="size-3.5" />
              </button>
            <% end %>
            <button
              type="button"
              phx-click="tmux:refresh_windows"
              class="ml-auto rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content"
              title="Refresh tmux windows"
            >
              <.icon name="hero-arrow-path" class="size-3.5" />
            </button>
          </div>
          <%!-- choose-tree style preview of the focused entry — filled client-side --%>
          <pre
            data-picker-preview
            class="mt-1 hidden max-h-44 w-80 overflow-hidden border-t border-base-300 px-2 pt-1 pb-1 font-mono text-[9px] leading-snug whitespace-pre text-base-content/70"
          ></pre>
        </div>
      </details>
      <div
        :if={is_map(@selected_preview)}
        id={"preview-titlebar-" <> preview_dom_frag(@selected_preview)}
        data-preview-pane-id={@selected_preview.pane_id}
        class="flex shrink-0 items-center gap-0.5 border-l border-sky-500/25 px-0.5"
        title={preview_title(@selected_preview)}
      >
        <span class="hidden max-w-44 truncate px-1 font-mono text-[10px] text-sky-700/75 md:inline dark:text-sky-200/75">
          {preview_compact_url(@selected_preview)}
        </span>
        <.preview_control_button
          id={"preview-back-" <> preview_dom_frag(@selected_preview)}
          event="preview-pane:back"
          pane_id={@selected_preview.pane_id}
          title={"Back in " <> preview_display_label(@selected_preview)}
          aria_label={"Back in " <> preview_display_label(@selected_preview)}
          icon="hero-arrow-left"
        />
        <.preview_control_button
          id={"preview-forward-" <> preview_dom_frag(@selected_preview)}
          event="preview-pane:forward"
          pane_id={@selected_preview.pane_id}
          title={"Forward in " <> preview_display_label(@selected_preview)}
          aria_label={"Forward in " <> preview_display_label(@selected_preview)}
          icon="hero-arrow-right"
        />
        <.preview_control_button
          id={"preview-refresh-" <> preview_dom_frag(@selected_preview)}
          event="preview-pane:refresh"
          pane_id={@selected_preview.pane_id}
          title={"Refresh " <> preview_display_label(@selected_preview)}
          aria_label={"Refresh " <> preview_display_label(@selected_preview)}
          icon="hero-arrow-path"
        />
        <a
          id={"preview-open-external-" <> preview_dom_frag(@selected_preview)}
          href={@selected_preview.display_url}
          target="_blank"
          rel="noreferrer"
          class="rounded p-1 text-sky-700/70 transition hover:bg-sky-500/15 hover:text-sky-800 dark:text-sky-200/70 dark:hover:text-sky-100"
          title={"Open " <> preview_display_label(@selected_preview) <> " externally"}
          aria-label={"Open " <> preview_display_label(@selected_preview) <> " externally"}
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
        </a>
        <.preview_control_button
          id={"preview-close-" <> preview_dom_frag(@selected_preview)}
          event="preview-pane:close"
          pane_id={@selected_preview.pane_id}
          title={"Close " <> preview_display_label(@selected_preview)}
          aria_label={"Close " <> preview_display_label(@selected_preview)}
          icon="hero-x-mark"
          class="hover:bg-error/10 hover:text-error"
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :pane_id, :string, required: true
  attr :title, :string, required: true
  attr :aria_label, :string, required: true
  attr :icon, :string, required: true
  attr :class, :string, default: ""

  defp preview_control_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-pane-id={@pane_id}
      class={[
        "rounded p-1 text-sky-700/70 transition hover:bg-sky-500/15 hover:text-sky-800 dark:text-sky-200/70 dark:hover:text-sky-100",
        @class
      ]}
      title={@title}
      aria-label={@aria_label}
    >
      <.icon name={@icon} class="size-3.5" />
    </button>
    """
  end

  defp preview_dom_frag(%{pane_id: pane_id}), do: dom_fragment(pane_id)

  defp preview_label(preview) do
    case Map.get(preview, :title) || Map.get(preview, "title") do
      title when is_binary(title) and title != "" -> title
      _ -> preview_host(preview)
    end
  end

  defp preview_display_label(preview) do
    case preview_actual_url(preview) do
      url when is_binary(url) and url != "" -> preview_host_for_url(url)
      _ -> preview_label(preview)
    end
  end

  defp preview_detail(preview) do
    preview
    |> preview_actual_url()
    |> preview_path_detail()
  end

  defp preview_compact_url(preview) do
    case {preview_display_label(preview), preview_detail(preview)} do
      {label, ""} -> label
      {label, detail} -> label <> detail
    end
  end

  defp preview_title(preview) do
    label = preview_label(preview)
    detail = preview_actual_url(preview)

    if is_binary(detail) and detail != "" and detail != label,
      do: label <> " · " <> detail,
      else: label
  end

  defp preview_host(preview) do
    case preview_actual_url(preview) do
      url when is_binary(url) and url != "" -> preview_host_for_url(url)
      _ -> "Preview"
    end
  end

  defp preview_host_for_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      is_binary(uri.host) and is_integer(uri.port) ->
        uri.host <> ":" <> Integer.to_string(uri.port)

      is_binary(uri.host) ->
        uri.host

      true ->
        preview_proxy_target_url(url) || url
    end
  end

  defp preview_display_url(preview) do
    Map.get(preview, :display_url) || Map.get(preview, "display_url") ||
      Map.get(preview, :url) || Map.get(preview, "url")
  end

  defp preview_actual_url(preview) do
    source_url = Map.get(preview, :source_url) || Map.get(preview, "source_url")
    url = Map.get(preview, :url) || Map.get(preview, "url")
    display_url = preview_display_url(preview)

    cond do
      is_binary(source_url) and source_url != "" ->
        source_url

      is_binary(url) and url != "" and not preview_proxy_url?(url) ->
        url

      is_binary(display_url) and display_url != "" ->
        preview_proxy_target_url(display_url) || display_url

      true ->
        nil
    end
  end

  defp preview_proxy_url?(url) when is_binary(url),
    do: String.starts_with?(url, "/preview-proxy/")

  defp preview_proxy_target_url("/preview-proxy/" <> rest) do
    case String.split(rest, "/", parts: 3) do
      [_workspace_id, port, path] ->
        case Integer.parse(port) do
          {port, ""} when port > 0 -> "http://localhost:#{port}/#{path}"
          _ -> nil
        end

      [_workspace_id, port] ->
        case Integer.parse(port) do
          {port, ""} when port > 0 -> "http://localhost:#{port}/"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp preview_proxy_target_url(_), do: nil

  defp preview_path_detail(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    case uri.query do
      query when is_binary(query) and query != "" -> path <> "?" <> query
      _ -> path
    end
  end

  defp preview_path_detail(_), do: ""

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

    "Pick a session (" <> session <> "). Shortcut: Ctrl + B, then S"
  end

  defp active_window_label(windows) do
    case Enum.find(windows, & &1.active?) do
      %{name: name} -> name
      nil -> "window"
    end
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

  # Pane rows deeplink to their parent window with the pane pre-selected so a
  # picker click (or a shared/new-tab open) lands inside that window on the
  # chosen pane. `session_window_href` drops the session when it's the default.
  defp pane_href(workspace_id, session_id, window_id, pane_id, path_base),
    do:
      session_window_href(workspace_id, session_id, window_id,
        pane: pane_id,
        path_base: path_base
      )

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
