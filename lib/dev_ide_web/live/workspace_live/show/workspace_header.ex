defmodule DevIdeWeb.WorkspaceLive.Show.WorkspaceHeader do
  @moduledoc false

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.TerminalChrome

  attr :desktop_terminal?, :boolean, default: false

  def header_overflow_menu(assigns) do
    ~H"""
    <details
      id={"header-overflow-" <> @workspace.id}
      phx-hook="HeaderOverflow"
      class="header-overflow relative shrink-0"
    >
      <summary
        class="flex cursor-pointer list-none select-none items-center justify-center rounded border border-base-300 px-1.5 py-0.5 text-base-content/70 transition hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:px-0 pointer-coarse:py-0 [&::-webkit-details-marker]:hidden"
        title="More workspace and terminal controls"
        aria-label="More header controls"
      >
        ⋯
      </summary>

      <div class="header-overflow-menu">
        <div class="px-3 py-1 text-[11px] text-base-content/70">
          <span class="rounded bg-base-200 px-1 py-0.5 uppercase">{@workspace.status}</span>
          <span :if={@workspace.branch} class="ml-1 font-mono text-base-content/60">
            {@workspace.branch}
          </span>
        </div>

        <button
          :if={not @desktop_terminal? and workspace_startable?(@workspace, @workspace_start_error)}
          id="workspace-start-menu-button"
          type="button"
          phx-click="workspace:start"
          class="block w-full px-3 py-1.5 text-left text-xs text-primary hover:bg-base-200"
        >
          Start workspace
        </button>

        <div
          :if={workspace_start_blocked?(@workspace_start_error)}
          class="px-3 py-1 text-[11px] text-amber-600 dark:text-amber-300"
        >
          Start unavailable
        </div>

        <button
          :if={not @desktop_terminal? and workspace_stoppable?(@workspace)}
          type="button"
          phx-click="workspace:stop"
          class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
        >
          Stop workspace
        </button>

        <%= if @tab == "terminal" and match?({:ok, _}, @host_loc) do %>
          <div class="my-0.5 border-t border-base-300/70"></div>

          <div class="px-3 py-1 text-[10px] uppercase tracking-wide text-base-content/40">
            {if @desktop_terminal?, do: "Terminal", else: "Windows"}
          </div>

          <button
            :if={@tmux_mutations_enabled?}
            type="button"
            phx-click="tmux:new_window"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="New window · Ctrl + B c"
            aria-label="New tmux window"
          >
            New window
          </button>

          <button
            :if={length(@tmux_window_tabs) > 1}
            type="button"
            phx-click="tmux:last_window"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Last window · Ctrl + B l"
          >
            Last window
          </button>

          <button
            type="button"
            phx-click="tmux:refresh_windows"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
          >
            {if @desktop_terminal?, do: "Refresh terminal", else: "Refresh windows"}
          </button>
          <button
            :if={@tmux_mutations_enabled?}
            id={"tmux-template-palette-" <> @workspace.id}
            type="button"
            phx-click="palette:templates"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
          >
            Apply session template
          </button>

          <button
            :if={@tmux_mutations_enabled?}
            id={"tmux-template-library-" <> @workspace.id}
            type="button"
            phx-click="tmux:open_template_library"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
          >
            Template library
          </button>
        <% end %>

        <%= if not @desktop_terminal? and @tab == "terminal" and
                @terminal_mode in [:raw, :raw_ghostty] do %>
          <div class="my-0.5 border-t border-base-300/70"></div>

          <div class="px-3 py-1 text-[10px] uppercase tracking-wide text-base-content/40">
            Panes
            <span class="ml-1 font-mono normal-case text-base-content/50">
              tmux {terminal_session_label(@tmux_session, @terminal_sid)}
            </span>
          </div>

          <%= if @active_window_pane_count > 1 do %>
            <button
              type="button"
              phx-click="pane:navigate"
              phx-value-dir="next"
              class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
              title="Cycle to next pane · Ctrl + B o"
            >
              Cycle to next pane
            </button>

            <button
              type="button"
              phx-click="pane:close_focused"
              class="block w-full px-3 py-1.5 text-left text-xs text-error/80 hover:bg-error/10 hover:text-error"
              title="Close pane · Ctrl + B x"
            >
              Close focused pane
            </button>

            <button
              type="button"
              phx-click="equalize_layout"
              class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            >
              Reset pane layout ({@active_window_pane_count} panes)
            </button>
          <% end %>
        <% end %>

        <%= if @tab == "terminal" do %>
          <div class="my-0.5 border-t border-base-300/70"></div>

          <div class="px-3 py-1 text-[10px] uppercase tracking-wide text-base-content/40">
            Sizing
          </div>

          <button
            type="button"
            data-keybar-key="FontDown"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Decrease terminal font size"
            aria-label="Decrease font size"
          >
            A− Smaller text
          </button>

          <button
            type="button"
            data-keybar-key="FontUp"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Increase terminal font size"
            aria-label="Increase font size"
          >
            A+ Larger text
          </button>

          <button
            type="button"
            data-keybar-key="ZoomDown"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Decrease display zoom (Ctrl + scroll)"
            aria-label="Decrease display zoom"
          >
            − Zoom out
          </button>

          <button
            type="button"
            data-keybar-key="ZoomReset"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Reset display zoom to 100%"
            aria-label="Reset display zoom"
          >
            1× Reset zoom
          </button>

          <button
            type="button"
            data-keybar-key="ZoomUp"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Increase display zoom (Ctrl + scroll)"
            aria-label="Increase display zoom"
          >
            + Zoom in
          </button>
        <% end %>
      </div>
    </details>
    """
  end

  @doc false
  def workspace_startable?(%{status: status}, nil),
    do: status in [:stopped, :error, "stopped", "error"]

  def workspace_startable?(_workspace, _start_error), do: false

  @doc false
  def workspace_start_blocked?(error), do: is_binary(error) and error != ""

  @doc false
  def workspace_stoppable?(%{status: status}), do: status in [:running, "running"]

  def workspace_stoppable?(_), do: false

  @doc false
  def workspace_status_dot_class(status) when status in [:running, "running"],
    do: "bg-emerald-500"

  def workspace_status_dot_class(status) when status in [:stopped, :error, "stopped", "error"],
    do: "bg-base-content/35"

  def workspace_status_dot_class(_status), do: "bg-amber-400"

  # On touch/narrow viewports the status dot doubles as the start/stop control
  # (see the header identity cluster). Returns the phx-click event for a tap, or
  # nil while the workspace is transitioning / start is blocked.
  @doc false
  def header_status_action(workspace, start_error) do
    cond do
      workspace_startable?(workspace, start_error) -> "workspace:start"
      workspace_stoppable?(workspace) -> "workspace:stop"
      true -> nil
    end
  end

  @doc false
  def header_status_action_label(workspace, start_error) do
    case header_status_action(workspace, start_error) do
      "workspace:start" -> "Start workspace"
      "workspace:stop" -> "Stop workspace"
      _ -> "Workspace status: " <> to_string(workspace.status)
    end
  end
end
