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
      <span class="shrink-0 px-1 text-[10px] font-semibold uppercase tracking-[0.18em] text-base-content/40">
        sessions
      </span>
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
end
