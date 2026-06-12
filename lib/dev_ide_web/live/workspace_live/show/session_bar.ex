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

  def session_tabs(assigns) do
    ~H"""
    <div
      id={"terminal-session-tabs-" <> @workspace_id}
      class="mb-2 flex shrink-0 items-center gap-1 overflow-x-auto border-b border-base-300/70 pb-1"
      aria-label="Terminal sessions"
    >
      <div class="flex min-w-0 flex-1 items-center gap-1">
        <button
          id={"terminal-session-shell-" <> @workspace_id}
          type="button"
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
        </button>
        <div id="active-sessions" class="contents">
          <%= for tab <- @tabs do %>
            <button
              id={tab.dom_id}
              type="button"
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
            </button>
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
            <button
              type="button"
              phx-click="tmux:select_window"
              phx-value-window-id={window.id}
              class="flex min-w-0 items-center gap-1"
              title={"Select tmux window " <> window.full_title}
            >
              <span class="font-mono text-[10px] text-base-content/45">{window.index}</span>
              <span class="max-w-36 truncate font-medium">{window.name}</span>
              <span
                id={"tmux-window-activity-" <> window.dom_frag}
                data-activity-state={window.activity_state}
                class={[
                  "size-1.5 shrink-0 rounded-full",
                  window.activity_class
                ]}
                title={window.activity_label}
                aria-label={window.activity_label}
              >
              </span>
              <span class="font-mono text-[10px] text-base-content/45">{window.command}</span>
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
  attr :shell_active?, :boolean, required: true
  attr :shell_label, :string, default: "workspace"
  attr :shell_detail, :string, default: ""
  attr :shell_title, :string, default: "Workspace shell"

  def session_dropdown(assigns) do
    ~H"""
    <details
      class="relative shrink-0"
      id={"session-dropdown-" <> @workspace_id}
      phx-hook="SessionPicker"
    >
      <summary
        data-leader-action="session-picker"
        phx-click={JS.push("terminal:refresh_sessions") |> JS.push("tmux:refresh_topology")}
        class="relative flex cursor-pointer list-none select-none items-center gap-1 rounded px-2 py-1 text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden"
      >
        <span class="flex flex-col items-start">
          <span class="max-w-[4.5rem] truncate font-medium sm:max-w-36">
            {active_session_label(@shell_active?, @shell_label, @tabs, @active_id)}
          </span>
          <span
            :if={active_session_detail(@shell_active?, @shell_detail, @tabs, @active_id) != ""}
            class="max-w-[4.5rem] truncate font-mono text-[10px] text-base-content/50 sm:max-w-36"
          >
            {active_session_detail(@shell_active?, @shell_detail, @tabs, @active_id)}
          </span>
        </span>
        <span class="text-[10px] text-base-content/40">▾</span>
        <kbd class="leader-kbd">s</kbd>
      </summary>
      <div class="absolute top-full left-0 z-50 mt-0.5 min-w-52 max-w-[90vw] rounded border border-base-300 bg-base-100 py-1 shadow-lg">
        <button
          id={"terminal-session-shell-" <> @workspace_id}
          type="button"
          data-picker-item
          data-picker-active={@shell_active?}
          phx-click={
            JS.push("terminal:switch_to_shell")
            |> JS.remove_attribute("open", to: "#session-dropdown-#{@workspace_id}")
          }
          class={dropdown_item_class(@shell_active?)}
          title={@shell_title}
        >
          <span class="truncate font-medium">{@shell_label}</span>
          <span :if={@shell_detail != ""} class="truncate font-mono text-[10px] text-base-content/50">
            {@shell_detail}
          </span>
        </button>
        <%= for tab <- @tabs do %>
          <div class={dropdown_row_class(@active_id == tab.id)}>
            <button
              id={tab.dom_id}
              type="button"
              data-picker-item
              data-picker-active={@active_id == tab.id}
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
              <span class="truncate font-medium">{tab.label}</span>
              <span :if={tab.detail != ""} class="truncate font-mono text-[10px] text-base-content/50">
                {tab.detail}
              </span>
            </button>
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
              <button
                type="button"
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
                class="flex w-full items-center gap-1 py-1 pr-3 pl-7 text-left text-xs text-base-content/60 hover:bg-base-200 hover:text-base-content"
                title={"Attach " <> tab.label <> " on window " <> window.name}
              >
                <span class="font-mono text-[10px] text-base-content/40">{window.index}</span>
                <span class="max-w-36 truncate">{window.name}</span>
                <span
                  :if={window.active?}
                  class="size-1.5 shrink-0 rounded-full bg-primary/70"
                  title="Active window"
                >
                </span>
              </button>
            <% end %>
          </div>
        <% end %>
        <%= for tab <- @workspace_tabs do %>
          <%= if tab.href do %>
            <.link
              id={tab.dom_id}
              navigate={tab.href}
              data-picker-item
              class={dropdown_item_class(false)}
              title={tab.title}
            >
              <span class="truncate font-medium">{tab.label}</span>
              <span :if={tab.detail != ""} class="truncate font-mono text-[10px] text-base-content/50">
                {tab.detail}
              </span>
            </.link>
          <% else %>
            <button
              id={tab.dom_id}
              type="button"
              class={[dropdown_item_class(false), "opacity-50 cursor-default"]}
              title={tab.title}
              disabled
            >
              <span class="truncate font-medium">{tab.label}</span>
              <span :if={tab.detail != ""} class="truncate font-mono text-[10px] text-base-content/50">
                {tab.detail}
              </span>
            </button>
          <% end %>
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
      </div>
    </details>
    """
  end

  attr :workspace_id, :string, required: true
  attr :windows, :list, required: true, doc: "SessionBarVM.window_tabs/1 view-models"
  attr :topology_version, :integer, default: 0
  attr :mutations_allowed?, :boolean, required: true
  attr :rename_window_id, :string, default: nil

  def window_dropdown(assigns) do
    ~H"""
    <details
      class="relative shrink-0"
      id={"window-dropdown-" <> @workspace_id}
      data-version={@topology_version}
      phx-hook="SessionPicker"
    >
      <summary
        data-leader-action="window-picker"
        phx-click="tmux:refresh_topology"
        class="relative flex cursor-pointer list-none select-none items-center gap-1 rounded px-2 py-1 text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden"
      >
        <span class="max-w-[4rem] truncate font-medium sm:max-w-28">
          {active_window_label(@windows)}
        </span>
        <span class="text-[10px] text-base-content/40">▾</span>
        <kbd class="leader-kbd">w</kbd>
      </summary>
      <div class="absolute top-full left-0 z-50 mt-0.5 min-w-52 max-w-[90vw] rounded border border-base-300 bg-base-100 py-1 shadow-lg">
        <%= for window <- @windows do %>
          <div
            id={"tmux-window-" <> window.dom_frag}
            class={[
              "group flex items-center gap-1 px-2 py-1 text-xs",
              if(window.active?,
                do: "bg-primary/5 text-primary",
                else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <button
              type="button"
              data-picker-item
              data-picker-active={window.active?}
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
              <span class="max-w-32 truncate font-medium">{window.name}</span>
              <span
                id={"tmux-window-activity-" <> window.dom_frag}
                data-activity-state={window.activity_state}
                class={["size-1.5 shrink-0 rounded-full", window.activity_class]}
                title={window.activity_label}
                aria-label={window.activity_label}
              >
              </span>
              <span class="font-mono text-[10px] text-base-content/40">{window.command}</span>
              <kbd class="leader-kbd">{window.index}</kbd>
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
                  data-leader-action={if window.active?, do: "rename-window"}
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
                class="rounded p-1 text-base-content/35 opacity-0 transition group-hover:opacity-100 hover:bg-error/10 hover:text-error"
                title="Close tmux window"
                disabled={length(@windows) <= 1}
              >
                <.icon name="hero-x-mark" class="size-3" />
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
              title="New window · C-b c"
            >
              <.icon name="hero-plus" class="size-3.5" />
            </button>
          <% end %>
          <%!-- Hidden sentinels: clicked by the leader key system for bindings with no visible button --%>
          <button
            type="button"
            phx-click="tmux:cycle_window"
            phx-value-dir="next"
            data-leader-action="next-window"
            class="sr-only"
            aria-hidden="true"
            tabindex="-1"
          >
            next window
          </button>
          <button
            type="button"
            phx-click="tmux:cycle_window"
            phx-value-dir="prev"
            data-leader-action="prev-window"
            class="sr-only"
            aria-hidden="true"
            tabindex="-1"
          >
            prev window
          </button>
          <button
            type="button"
            phx-click="tmux:refresh_windows"
            class="ml-auto rounded p-1 text-base-content/50 hover:bg-base-200 hover:text-base-content"
            title="Refresh tmux windows"
          >
            <.icon name="hero-arrow-path" class="size-3.5" />
          </button>
        </div>
      </div>
    </details>
    """
  end

  defp active_session_label(true, shell_label, _tabs, _active_id), do: shell_label

  defp active_session_label(false, _shell_label, tabs, active_id) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{label: label} -> label
      nil -> "session"
    end
  end

  defp active_session_detail(true, shell_detail, _tabs, _active_id), do: shell_detail

  defp active_session_detail(false, _shell_detail, tabs, active_id) do
    case Enum.find(tabs, &(&1.id == active_id)) do
      %{detail: detail} -> detail
      nil -> ""
    end
  end

  defp active_window_label(windows) do
    case Enum.find(windows, & &1.active?) do
      %{name: name} -> name
      nil -> "window"
    end
  end

  defp dropdown_item_class(true),
    do: "flex w-full flex-col items-start px-3 py-1.5 text-left text-xs bg-primary/5 text-primary"

  defp dropdown_item_class(false),
    do:
      "flex w-full flex-col items-start px-3 py-1.5 text-left text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"

  defp dropdown_row_class(true),
    do: "flex w-full items-center px-3 py-1.5 text-xs bg-primary/5 text-primary"

  defp dropdown_row_class(false),
    do:
      "flex w-full items-center px-3 py-1.5 text-xs text-base-content/70 hover:bg-base-200 hover:text-base-content"
end
