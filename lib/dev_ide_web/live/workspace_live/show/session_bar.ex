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
          href={"/workspaces/#{@workspace_id}"}
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
              href={session_href(@workspace_id, tab.id)}
              phx-click="attach_terminal_session"
              phx-value-session-id={tab.id}
              phx-value-kind={Atom.to_string(tab.kind)}
              phx-value-tmux-session={tab.tmux_session}
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

  def window_tabs(assigns) do
    ~H"""
    <div
      :if={@windows != []}
      id={"tmux-window-tabs-" <> @workspace_id}
      data-version={@topology_version}
      class="mb-2 flex shrink-0 items-center gap-1 overflow-x-auto border-b border-base-300 pb-1"
    >
      <div class="flex min-w-0 flex-1 items-center gap-1">
        <%= for window <- @windows do %>
          <div
            id={"tmux-window-" <> window.dom_frag}
            class={[
              "group flex max-w-64 shrink-0 items-center gap-1 rounded-t border border-b-0 px-2 py-1 text-xs transition-colors",
              if(window.active?,
                do: "border-primary bg-base-100 text-base-content shadow-sm",
                else:
                  "border-base-300 bg-base-200/70 text-base-content/65 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <a
              href={window_href(@workspace_id, window.id)}
              phx-click="tmux:select_window"
              phx-value-window-id={window.id}
              class="flex min-w-0 items-center gap-1"
              title={"Select tmux window " <> window.full_title}
            >
              <span class="font-mono text-[10px] text-base-content/45">{window.index}</span>
              <span class="max-w-36 truncate font-medium">{window.name}</span>
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
              <span class="font-mono text-[10px] text-base-content/45">{window.command}</span>
            </a>
            <a
              href={window_href(@workspace_id, window.id)}
              target="_blank"
              rel="noreferrer"
              tabindex="-1"
              class="shrink-0 rounded p-0.5 opacity-0 transition group-hover:opacity-100 hover:bg-base-300/60"
              title="Open in new tab"
              aria-label={"Open window " <> window.name <> " in new tab"}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
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
                  <.input
                    field={to_form(%{"name" => window.name}, as: :window)[:name]}
                    type="text"
                    value={window.name}
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
          id={"tmux-template-palette-" <> @workspace_id}
          type="button"
          phx-click="palette:templates"
          class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
          title="Apply session template"
          aria-label="Apply session template"
        >
          <.icon name="hero-bars-3-bottom-left" class="size-4" />
        </button>
        <button
          id={"tmux-template-library-" <> @workspace_id}
          type="button"
          phx-click="tmux:open_template_library"
          class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
          title="Session template library"
          aria-label="Session template library"
        >
          <.icon name="hero-book-open" class="size-4" />
        </button>
        <button
          type="button"
          phx-click="tmux:new_window"
          class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/65 transition hover:border-primary/50 hover:bg-primary/10 hover:text-primary"
          title="New tmux window"
          aria-label="New tmux window"
        >
          <.icon name="hero-plus" class="size-4" />
        </button>
      <% end %>
      <button
        type="button"
        phx-click="tmux:refresh_windows"
        class="shrink-0 rounded border border-base-300 p-1.5 text-base-content/55 transition hover:bg-base-200 hover:text-base-content"
        title="Refresh tmux windows"
        aria-label="Refresh tmux windows"
      >
        <.icon name="hero-arrow-path" class="size-4" />
      </button>
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
  attr :shell_active?, :boolean, required: true
  attr :shell_label, :string, default: "workspace"
  attr :shell_detail, :string, default: ""
  attr :shell_title, :string, default: "Workspace shell"
  attr :active_fallback_label, :string, default: "session"
  attr :active_fallback_detail, :string, default: ""

  def session_dropdown(assigns) do
    ~H"""
    <details
      class="leader-key-control relative shrink-0"
      id={"session-dropdown-" <> @workspace_id}
      data-shortcut="Ctrl + B, then S"
      phx-hook="SessionPicker"
    >
      <summary
        data-leader-action="session-picker"
        phx-click={JS.push("terminal:refresh_sessions") |> JS.push("tmux:refresh_topology")}
        title={
          active_session_picker_title(
            @shell_active?,
            @shell_label,
            @shell_detail,
            @tabs,
            @active_id,
            @active_fallback_label,
            @active_fallback_detail
          )
        }
        class="flex cursor-pointer list-none select-none items-center gap-1 rounded px-1.5 py-0.5 text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden"
      >
        <% summary_label =
          active_session_label(
            @shell_active?,
            @shell_label,
            @tabs,
            @active_id,
            @active_fallback_label
          )

        summary_detail =
          active_session_detail(
            @shell_active?,
            @shell_detail,
            @tabs,
            @active_id,
            @active_fallback_detail
          ) %>
        <span class="max-w-[5rem] truncate font-medium sm:max-w-44">
          {summary_label}
          <span
            :if={summary_detail != "" and summary_detail != summary_label}
            class="font-mono font-normal text-base-content/50"
          >
            {" · " <> summary_detail}
          </span>
        </span>
        <span
          :if={quiet_window_count(@tabs) > 0}
          id={"session-quiet-badge-" <> @workspace_id}
          class="size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
          title={quiet_badge_label(quiet_window_count(@tabs))}
          aria-label={quiet_badge_label(quiet_window_count(@tabs))}
        ></span>
        <span class="text-[10px] text-base-content/40">▾</span>
      </summary>
      <div class="absolute top-full left-0 z-50 mt-0.5 min-w-52 max-w-[90vw] rounded border border-base-300 bg-base-100 py-1 shadow-lg">
        <%!-- Type-to-filter readout — populated client-side by SessionPicker --%>
        <div
          data-picker-filter
          class="hidden border-b border-base-300 px-3 py-1 font-mono text-[10px] text-base-content/60"
        >
        </div>
        <a
          id={"terminal-session-shell-" <> @workspace_id}
          href={"/workspaces/#{@workspace_id}"}
          data-picker-item
          data-picker-active={@shell_active? || nil}
          phx-click={
            JS.push("terminal:switch_to_shell")
            |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
          }
          class={dropdown_item_class(@shell_active?)}
          title={@shell_title}
        >
          <span class="flex min-w-0 flex-1 flex-col items-start">
            <span data-picker-label class="truncate font-medium">{@shell_label}</span>
            <span
              :if={@shell_detail != ""}
              data-picker-label
              class="truncate font-mono text-[10px] text-base-content/50"
            >
              {@shell_detail}
            </span>
          </span>
          <span
            class="shrink-0 opacity-0 transition-opacity group-hover:opacity-100"
            title="Cmd/Ctrl-click to open in new tab"
          >
            <.icon name="hero-arrow-top-right-on-square" class="size-3" />
          </span>
        </a>
        <%= for tab <- @tabs do %>
          <div class={dropdown_row_class(@active_id == tab.id)}>
            <a
              id={tab.dom_id}
              href={session_href(@workspace_id, tab.id)}
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
                <span data-picker-label class="truncate font-medium">{tab.label}</span>
                <.preview_badge
                  count={preview_pane_count(tab.pane_ids, @preview_panes)}
                  id={"session-preview-" <> tab.dom_id}
                  scope="session"
                />
                <span
                  :if={tab.quiet_count > 0}
                  id={"session-quiet-" <> tab.dom_id}
                  class="size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
                  title={quiet_badge_label(tab.quiet_count)}
                  aria-label={quiet_badge_label(tab.quiet_count)}
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
            <a
              href={session_href(@workspace_id, tab.id)}
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
          </div>
          <div :if={tab.windows != []} id={"session-windows-" <> tab.dom_id} class="hidden">
            <%= for window <- tab.windows do %>
              <a
                href={session_window_href(@workspace_id, tab.id, window.id)}
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
                class="group flex w-full items-center gap-1 py-1 pr-3 pl-7 text-left text-xs text-base-content/60 hover:bg-base-200 hover:text-base-content"
                title={"Attach " <> tab.label <> " on window " <> window.name}
              >
                <span class="font-mono text-[10px] text-base-content/40">{window.index}</span>
                <span data-picker-label class="max-w-36 truncate">{window.name}</span>
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
                  class="size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
                  title="Agent pane quiet — likely finished or awaiting input"
                  aria-label="Agent pane quiet — likely finished or awaiting input"
                ></span>
                <span
                  :if={not window.active? and not window.quiet? and window.activity_state != :idle}
                  data-activity-state={window.activity_state}
                  class={["size-1.5 shrink-0 rounded-full", window.activity_class]}
                  title={window.activity_label}
                  aria-label={window.activity_label}
                ></span>
                <span
                  class="ml-auto shrink-0 opacity-0 transition-opacity group-hover:opacity-100"
                  title="Cmd/Ctrl-click to open in new tab"
                >
                  <.icon name="hero-arrow-top-right-on-square" class="size-3" />
                </span>
              </a>
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
                  <span
                    :if={tab.quiet_count > 0}
                    id={"session-quiet-" <> tab.dom_id}
                    class="size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
                    title={quiet_badge_label(tab.quiet_count)}
                    aria-label={quiet_badge_label(tab.quiet_count)}
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
                title={"Open " <> tab.label <> " on window " <> window.name}
              >
                <span class="font-mono text-[10px] text-base-content/40">{window.index}</span>
                <span data-picker-label class="max-w-36 truncate">{window.name}</span>
                <span
                  :if={window.active?}
                  class="size-1.5 shrink-0 rounded-full bg-primary/70"
                  title="Active window"
                ></span>
                <span
                  :if={window.quiet?}
                  data-quiet="true"
                  class="size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
                  title="Agent pane quiet — likely finished or awaiting input"
                  aria-label="Agent pane quiet — likely finished or awaiting input"
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

  attr :topology_version, :integer, default: 0
  attr :mutations_allowed?, :boolean, required: true
  attr :rename_window_id, :string, default: nil

  def window_dropdown(assigns) do
    ~H"""
    <details
      class="leader-key-control relative shrink-0"
      id={"window-dropdown-" <> @workspace_id}
      data-version={@topology_version}
      data-shortcut="Ctrl + B, then W"
      data-picker-hop-left={"#session-dropdown-" <> @workspace_id}
      phx-hook="SessionPicker"
    >
      <summary
        data-leader-action="window-picker"
        phx-click="tmux:refresh_topology"
        title="Pick a window. Shortcut: Ctrl + B, then W"
        class="flex cursor-pointer list-none select-none items-center gap-1 rounded px-1.5 py-0.5 text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden"
      >
        <span class="max-w-[4rem] truncate font-medium sm:max-w-28">
          {active_window_label(@windows)}
        </span>
        <span class="text-[10px] text-base-content/40">▾</span>
      </summary>
      <div class="absolute top-full left-0 z-50 mt-0.5 min-w-52 max-w-[90vw] rounded border border-base-300 bg-base-100 py-1 shadow-lg">
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
              href={window_href(@workspace_id, @session_id, window.id)}
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
              <span data-picker-label class="max-w-32 truncate font-medium">{window.name}</span>
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
                class="size-1.5 shrink-0 rounded-full bg-violet-400 shadow-[0_0_0_3px_rgba(167,139,250,0.25)]"
                title="Agent pane quiet — likely finished or awaiting input"
                aria-label="Agent pane quiet — likely finished or awaiting input"
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
            <a
              href={window_href(@workspace_id, @session_id, window.id)}
              target="_blank"
              rel="noreferrer"
              tabindex="-1"
              class="shrink-0 rounded p-1 opacity-0 transition group-hover:opacity-100 hover:bg-base-300/60"
              title="Open in new tab"
              aria-label={"Open window " <> window.name <> " in new tab"}
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-3" />
            </a>
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
                  <.input
                    field={to_form(%{"name" => window.name}, as: :window)[:name]}
                    type="text"
                    value={window.name}
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
                class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-error/10 hover:text-error"
                title="Close tmux window"
                disabled={length(@windows) <= 1}
              >
                <.icon name="hero-x-mark" class="size-3" />
              </button>
            <% end %>
          </div>
          <div :if={window.panes != []} id={"window-panes-" <> window.dom_frag} class="hidden">
            <%= for pane <- window.panes do %>
              <button
                type="button"
                id={"window-pane-" <> pane.dom_frag}
                data-picker-item
                data-picker-parent={"window-panes-" <> window.dom_frag}
                data-picker-active={pane.active? || nil}
                phx-click={
                  JS.push("tmux:select_pane", value: %{"pane-id" => pane.id})
                  |> JS.remove_attribute("open", to: "#window-dropdown-#{@workspace_id}")
                }
                class={[
                  "group flex w-full items-center gap-1.5 py-1 pr-3 pl-7 text-left text-xs",
                  if(pane.active?,
                    do: "bg-primary/5 text-primary",
                    else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
                  )
                ]}
                title={pane.title}
              >
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
                  <span data-picker-label class="max-w-44 truncate font-medium">{pane.label}</span>
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
              </button>
            <% end %>
          </div>
        <% end %>
        <div class="mt-1 flex items-center gap-0.5 border-t border-base-300 px-2 pt-1">
          <%= if @mutations_allowed? do %>
            <button
              id={"tmux-template-palette-" <> @workspace_id}
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
              id={"tmux-template-library-" <> @workspace_id}
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
    """
  end

  attr :preview, :map, default: nil, doc: "selected preview pane registration"

  def preview_titlebar(assigns) do
    ~H"""
    <div
      :if={is_map(@preview)}
      id={"preview-titlebar-" <> preview_dom_frag(@preview)}
      data-preview-pane-id={@preview.pane_id}
      class="hidden min-w-0 shrink items-center gap-1 rounded border border-sky-500/25 bg-sky-500/10 px-1 py-0.5 text-xs text-sky-700 sm:flex dark:text-sky-200"
      title={preview_title(@preview)}
    >
      <span class="inline-flex size-5 shrink-0 items-center justify-center rounded bg-sky-500/15 text-sky-600 dark:text-sky-300">
        <.icon name="hero-globe-alt" class="size-3" />
      </span>
      <span class="min-w-0 max-w-48 truncate font-medium">{preview_label(@preview)}</span>
      <span
        :if={preview_detail(@preview) != ""}
        class="hidden max-w-40 truncate font-mono text-[10px] text-sky-700/70 lg:inline dark:text-sky-200/65"
      >
        {preview_detail(@preview)}
      </span>
      <span class="mx-0.5 h-4 w-px shrink-0 bg-sky-500/25"></span>
      <.preview_control_button
        id={"preview-back-" <> preview_dom_frag(@preview)}
        event="preview-pane:back"
        pane_id={@preview.pane_id}
        title={"Back in " <> preview_label(@preview)}
        aria_label={"Back in " <> preview_label(@preview)}
        icon="hero-arrow-left"
      />
      <.preview_control_button
        id={"preview-forward-" <> preview_dom_frag(@preview)}
        event="preview-pane:forward"
        pane_id={@preview.pane_id}
        title={"Forward in " <> preview_label(@preview)}
        aria_label={"Forward in " <> preview_label(@preview)}
        icon="hero-arrow-right"
      />
      <.preview_control_button
        id={"preview-refresh-" <> preview_dom_frag(@preview)}
        event="preview-pane:refresh"
        pane_id={@preview.pane_id}
        title={"Refresh " <> preview_label(@preview)}
        aria_label={"Refresh " <> preview_label(@preview)}
        icon="hero-arrow-path"
      />
      <a
        id={"preview-open-external-" <> preview_dom_frag(@preview)}
        href={@preview.display_url}
        target="_blank"
        rel="noreferrer"
        class="rounded p-1 text-sky-700/70 transition hover:bg-sky-500/15 hover:text-sky-800 dark:text-sky-200/70 dark:hover:text-sky-100"
        title={"Open " <> preview_label(@preview) <> " externally"}
        aria-label={"Open " <> preview_label(@preview) <> " externally"}
      >
        <.icon name="hero-arrow-top-right-on-square" class="size-3.5" />
      </a>
      <.preview_control_button
        id={"preview-close-" <> preview_dom_frag(@preview)}
        event="preview-pane:close"
        pane_id={@preview.pane_id}
        title={"Close " <> preview_label(@preview)}
        aria_label={"Close " <> preview_label(@preview)}
        icon="hero-x-mark"
        class="hover:bg-error/10 hover:text-error"
      />
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

  defp preview_detail(preview) do
    preview
    |> preview_display_url()
    |> preview_path_detail()
  end

  defp preview_title(preview) do
    label = preview_label(preview)
    detail = preview_display_url(preview)

    if is_binary(detail) and detail != "" and detail != label,
      do: label <> " · " <> detail,
      else: label
  end

  defp preview_host(preview) do
    case preview_display_url(preview) do
      url when is_binary(url) and url != "" ->
        uri = URI.parse(url)
        uri.host || url

      _ ->
        "Preview"
    end
  end

  defp preview_display_url(preview) do
    Map.get(preview, :display_url) || Map.get(preview, "display_url") ||
      Map.get(preview, :url) || Map.get(preview, "url")
  end

  defp preview_path_detail(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)
    path = if uri.path in [nil, ""], do: "/", else: uri.path

    case uri.query do
      query when is_binary(query) and query != "" -> path <> "?" <> query
      _ -> path
    end
  end

  defp preview_path_detail(_), do: ""

  defp active_session_label(true, shell_label, _tabs, _active_id, _fallback_label),
    do: shell_label

  defp active_session_label(false, _shell_label, tabs, active_id, fallback_label) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{label: label} -> label
      nil -> fallback_label
    end
  end

  defp active_session_detail(true, shell_detail, _tabs, _active_id, _fallback_detail),
    do: shell_detail

  defp active_session_detail(false, _shell_detail, tabs, active_id, fallback_detail) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{detail: detail} -> detail
      nil -> fallback_detail
    end
  end

  defp active_session_picker_title(
         shell_active?,
         shell_label,
         shell_detail,
         tabs,
         active_id,
         fallback_label,
         fallback_detail
       ) do
    label =
      active_session_label(shell_active?, shell_label, tabs, active_id, fallback_label)

    detail =
      active_session_detail(shell_active?, shell_detail, tabs, active_id, fallback_detail)

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

  defp session_href(workspace_id, session_id),
    do: "/workspaces/#{workspace_id}?session=#{URI.encode_www_form(session_id)}"

  defp window_href(workspace_id, window_id),
    do: "/workspaces/#{workspace_id}?window=#{URI.encode_www_form(window_id)}"

  # Preserve the active (non-default) session when switching windows so a bare
  # <a href> navigation (e.g. a mobile tap that beats the phx-click push) doesn't
  # land on `?window=X` with no session and get reset to the default session.
  defp window_href(workspace_id, session_id, window_id)
       when is_binary(session_id) and session_id != "",
       do: session_window_href(workspace_id, session_id, window_id)

  defp window_href(workspace_id, _session_id, window_id),
    do: window_href(workspace_id, window_id)

  defp session_window_href(workspace_id, session_id, window_id),
    do:
      "/workspaces/#{workspace_id}?session=#{URI.encode_www_form(session_id)}&window=#{URI.encode_www_form(window_id)}"

  defp dropdown_item_class(true),
    do:
      "group flex w-full items-center gap-1 px-3 py-1.5 text-left text-xs bg-primary/5 text-primary"

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

  defp quiet_badge_label(1), do: "1 quiet agent window"
  defp quiet_badge_label(count), do: "#{count} quiet agent windows"
end
