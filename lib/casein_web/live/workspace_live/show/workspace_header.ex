defmodule CaseinWeb.WorkspaceLive.Show.WorkspaceHeader do
  @moduledoc false

  use CaseinWeb, :html

  import CaseinWeb.WorkspaceLive.Show.TerminalChrome

  attr :desktop_terminal?, :boolean, default: false
  attr :notif_unread_count, :integer, default: 0
  attr :agent_approval_count, :integer, default: 0
  attr :desktop_downloads, :list, default: []

  attr :active_window_pane_count, :any, required: true
  attr :host_loc, :any, required: true
  attr :tab, :any, required: true
  attr :terminal_mode, :any, required: true
  attr :terminal_sid, :any, required: true
  attr :tmux_mutations_enabled?, :any, required: true
  attr :tmux_session, :any, required: true
  attr :tmux_window_tabs, :any, required: true
  attr :workspace, :any, required: true
  attr :workspace_start_error, :any, required: true
  attr :host_health, :map, default: nil

  def header_overflow_menu(assigns) do
    assigns =
      assign(assigns, :host_health, assigns.host_health || Casein.Terminals.HostHealth.snapshot())

    ~H"""
    <span
      id={"agent-approval-announcer-" <> @workspace.id}
      class="sr-only"
      aria-live="assertive"
      aria-atomic="true"
    >
      <%= if @agent_approval_count > 0 do %>
        {@agent_approval_count} agent approval{if @agent_approval_count == 1,
          do: "",
          else: "s"} waiting in Notifications.
      <% end %>
    </span>
    <details
      id={"header-overflow-" <> @workspace.id}
      phx-hook="HeaderOverflow"
      class="header-overflow relative shrink-0"
    >
      <summary
        class="relative flex cursor-pointer list-none select-none items-center justify-center rounded border border-base-300 px-1.5 py-0.5 text-base-content/70 transition hover:bg-base-200 pointer-coarse:size-8 pointer-coarse:px-0 pointer-coarse:py-0 [&::-webkit-details-marker]:hidden"
        title={header_overflow_title(@agent_approval_count)}
        aria-label={header_overflow_title(@agent_approval_count)}
      >
        ⋯
        <span
          :if={@agent_approval_count > 0}
          id={"header-agent-approval-count-" <> @workspace.id}
          class="absolute -right-1.5 -top-1.5 inline-flex min-w-4 items-center justify-center rounded-full bg-status-warning px-1 text-density-badge font-bold leading-4 text-status-warning-fg ring-2 ring-base-100"
        >
          {min(@agent_approval_count, 99)}
        </span>
      </summary>

      <div class="header-overflow-menu">
        <div class="px-3 py-1 text-density-body text-base-content/70">
          <span class="rounded bg-base-200 px-1 py-0.5 uppercase">{@workspace.status}</span>
          <span :if={@workspace.branch} class="ml-1 font-mono text-base-content/60">
            {@workspace.branch}
          </span>
        </div>

        <.host_health_row health={@host_health} workspace_id={@workspace.id} />

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
          class="px-3 py-1 text-density-body text-status-warning-fg"
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

          <div class="px-3 py-1 text-density-label uppercase tracking-wide text-base-content/40">
            {if @desktop_terminal?, do: "Terminal", else: "Windows"}
          </div>

          <button
            :if={@tmux_mutations_enabled?}
            type="button"
            phx-click="tmux:new_window"
            class={menu_item_class()}
            title="New window · Ctrl + B c"
            aria-label="New tmux window"
          >
            <span>New window</span>
            <.menu_kbd keys="Ctrl B c" />
          </button>

          <button
            :if={length(@tmux_window_tabs) > 1}
            type="button"
            phx-click="tmux:last_window"
            class={menu_item_class()}
            title="Last window · Ctrl + B l"
          >
            <span>Last window</span>
            <.menu_kbd keys="Ctrl B l" />
          </button>

          <%!-- No "Refresh windows" item: the topology watcher tracks tmux on
                its own (control-mode events, or a 300ms poll when those are
                off, with a 10s reconcile behind both) and now resubscribes
                itself if the watcher dies, so a manual poke has nothing left to
                fix. The desktop app keeps its terminal restart — that one
                respawns the PTY, it is not a refresh. --%>
          <button
            :if={@desktop_terminal?}
            type="button"
            phx-click="tmux:refresh_windows"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
          >
            Restart terminal
          </button>
          <%!-- One templates entry, not two. The old "Apply session template"
                row only opened the command palette filtered to "template apply"
                — a shortcut for something the Command palette row already
                reaches, sitting next to a library that applies templates too.
                The library is the whole feature: save, tag, edit, apply. --%>
          <button
            :if={@tmux_mutations_enabled?}
            id={"tmux-template-library-" <> @workspace.id}
            type="button"
            phx-click="tmux:open_template_library"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
          >
            Session templates…
          </button>
        <% end %>

        <%= if not @desktop_terminal? and @tab == "terminal" and
                @terminal_mode in [:raw, :raw_ghostty] do %>
          <div class="my-0.5 border-t border-base-300/70"></div>

          <div class="px-3 py-1 text-density-label uppercase tracking-wide text-base-content/40">
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
              class={menu_item_class()}
              title="Cycle to next pane · Ctrl + B o"
            >
              <span>Cycle to next pane</span>
              <.menu_kbd keys="Ctrl B o" />
            </button>

            <button
              type="button"
              phx-click="pane:close_focused"
              class={menu_item_class("text-error/80 hover:bg-error/10 hover:text-error")}
              title="Close pane · Ctrl + B x"
            >
              <span>Close focused pane</span>
              <.menu_kbd keys="Ctrl B x" />
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

          <div class="px-3 py-1 text-density-label uppercase tracking-wide text-base-content/40">
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

        <%!-- Tablet/desktop chrome layout (#736). Client-persisted like sidebar
             sort: auto follows width+pointer+keyboard evidence; compact/desktop
             force the treatment. Dispatched as casein:cockpit-layout. --%>
        <div class="my-0.5 border-t border-base-300/70"></div>

        <div class="px-3 py-1 text-density-label uppercase tracking-wide text-base-content/40">
          Layout
        </div>

        <div
          id={"cockpit-layout-override-" <> @workspace.id}
          class="flex flex-col"
          phx-hook="CockpitLayoutOverride"
        >
          <button
            type="button"
            data-cockpit-layout-mode="auto"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Auto: compact on bare tablet/phone; desktop when a keyboard is present"
          >
            Auto (width + keyboard)
          </button>
          <button
            type="button"
            data-cockpit-layout-mode="compact"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Always use compact mobile chrome"
          >
            Compact
          </button>
          <button
            type="button"
            data-cockpit-layout-mode="desktop"
            class="block w-full px-3 py-1.5 text-left text-xs hover:bg-base-200"
            title="Always use desktop cockpit chrome (touch targets still grow on coarse pointers)"
          >
            Desktop cockpit
          </button>
        </div>

        <%!-- Global surfaces live at the foot of the menu: notifications, then
              the palette, then help pinned last. Notification state is only
              surfaced once the menu is open (no ambient badge on the ⋯). --%>
        <div class="my-0.5 border-t border-base-300/70"></div>

        <button
          id={"notifications-open-" <> @workspace.id}
          type="button"
          phx-click="notifications:toggle"
          class="flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left text-xs hover:bg-base-200"
          title="Open notifications"
          aria-label="Open notifications"
        >
          <span>Notifications</span>
          <span
            :if={notification_attention_count(assigns) > 0}
            id={"notifications-open-" <> @workspace.id <> "-count"}
            class={[
              "inline-flex min-w-4 items-center justify-center rounded-full px-1 text-density-label font-semibold leading-4",
              if((@notif_unread_count || 0) > 0,
                do: "bg-status-danger text-white",
                else: "bg-status-warning text-status-warning-content"
              )
            ]}
          >
            {notification_attention_count(assigns)}
          </span>
        </button>

        <button
          type="button"
          phx-click="palette:open"
          class={menu_item_class()}
          title="Open command palette · Ctrl + P"
          aria-label="Open command palette"
        >
          <span>Command palette</span>
          <.menu_kbd keys="Ctrl P" />
        </button>

        <details :if={@desktop_downloads != []} class="group/download">
          <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-1.5 text-left text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden">
            <span>Download Casein</span>
            <.icon name="hero-chevron-right" class="size-3 transition group-open/download:rotate-90" />
          </summary>
          <a
            :for={platform <- @desktop_downloads}
            href={platform.url}
            download
            class="block w-full py-1.5 pl-6 pr-3 text-left text-xs text-base-content/80 hover:bg-base-200"
          >
            {platform.label}
          </a>
          <div
            :for={platform <- @desktop_downloads}
            class="px-6 pb-1.5 text-density-badge text-base-content/50"
          >
            SHA-256
            <a href={platform.sha256_url} class="ml-1 break-all font-mono hover:text-primary">
              {platform.sha256}
            </a>
          </div>
        </details>

        <button
          type="button"
          phx-click="leader_help:toggle"
          class={menu_item_class()}
          title="Help & keyboard shortcuts · Ctrl + B ?"
          aria-label="Help and keyboard shortcuts"
        >
          <span>Help &amp; shortcuts</span>
          <.menu_kbd keys="Ctrl B ?" />
        </button>
      </div>
    </details>
    """
  end

  attr :health, :map, required: true
  attr :workspace_id, :string, required: true

  defp host_health_row(assigns) do
    ~H"""
    <details
      id={"host-health-" <> @workspace_id}
      class="group/host-health"
      data-host-health-state={@health.state}
      data-host-health-sampled-at={@health.sampled_at}
    >
      <summary class="flex cursor-pointer list-none items-center justify-between gap-3 px-3 py-1.5 text-left text-xs hover:bg-base-200 [&::-webkit-details-marker]:hidden">
        <span class="flex min-w-0 items-center gap-2">
          <span class={["size-1.5 shrink-0 rounded-full", host_health_dot_class(@health.state)]}></span>
          <span>Host health</span>
        </span>
        <span class={["shrink-0 font-medium", host_health_label_class(@health.state)]}>
          {@health.state_label}
          <span :if={@health.age_seconds} class="font-normal text-base-content/50">
            · {host_health_age(@health.age_seconds)}
          </span>
        </span>
      </summary>

      <div class="space-y-1 px-3 pb-2 text-density-label text-base-content/70">
        <div class="font-mono text-base-content/60" title={@health.sampled_at}>
          {@health.host}
          <span :if={@health.reason} class={host_health_label_class(@health.state)}>
            · {@health.reason}
          </span>
        </div>
        <div class="flex flex-wrap gap-x-2 gap-y-0.5 font-mono">
          <span>load {host_health_number(@health.load1)}</span>
          <span>idle {host_health_pct(@health.cpu_idle_pct)}</span>
          <span>mem {host_health_mem(@health.mem_available_kb)}</span>
          <span>swap {host_health_mem(@health.swap_used_kb)}</span>
          <span>oc {host_health_count(@health.opencode_processes)}</span>
          <span>beam {host_health_count(@health.beam_processes)}</span>
        </div>
        <div>
          alert {host_health_alert(@health.alert)}
          <span :if={@health.latest_alert_at} class="text-base-content/50">
            · {@health.latest_alert_at}
          </span>
        </div>
        <div :if={@health.alerts == []} class="text-base-content/50">No recent alerts</div>
        <ul :if={@health.alerts != []} class="space-y-0.5">
          <li :for={alert <- @health.alerts} class="font-mono">
            {Map.get(alert, :timestamp) || "—"}
            {Map.get(alert, :signal) || "alert"}
            {Map.get(alert, :message)}
          </li>
        </ul>
      </div>
    </details>
    """
  end

  defp host_health_dot_class("healthy"), do: "bg-status-ok"
  defp host_health_dot_class("warning"), do: "bg-status-warning"
  defp host_health_dot_class("pressure"), do: "bg-status-danger"
  defp host_health_dot_class("stuck"), do: "bg-status-danger"
  defp host_health_dot_class(_), do: "bg-base-content/35"

  defp host_health_label_class("healthy"), do: "text-status-ok-fg"
  defp host_health_label_class("warning"), do: "text-status-warning-fg"
  defp host_health_label_class("pressure"), do: "text-status-danger-fg"
  defp host_health_label_class("stuck"), do: "text-status-danger-fg"
  defp host_health_label_class(_), do: "text-base-content/60"

  defp host_health_age(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"

  defp host_health_age(seconds) when is_integer(seconds) and seconds < 3600,
    do: "#{div(seconds, 60)}m"

  defp host_health_age(seconds) when is_integer(seconds), do: "#{div(seconds, 3600)}h"
  defp host_health_age(_), do: "n/a"

  defp host_health_number(nil), do: "—"

  defp host_health_number(value) when is_float(value),
    do: :erlang.float_to_binary(value, decimals: 2)

  defp host_health_number(value), do: to_string(value)

  defp host_health_pct(nil), do: "—"
  defp host_health_pct(value), do: "#{value}%"

  defp host_health_count(nil), do: "—"
  defp host_health_count(value), do: to_string(value)

  defp host_health_mem(nil), do: "—"

  defp host_health_mem(kb) when is_integer(kb) and kb >= 1_048_576,
    do: "#{Float.round(kb / 1_048_576, 1)}G"

  defp host_health_mem(kb) when is_integer(kb) and kb >= 1024, do: "#{div(kb, 1024)}M"
  defp host_health_mem(kb) when is_integer(kb), do: "#{kb}K"
  defp host_health_mem(_), do: "—"

  defp host_health_alert(nil), do: "—"
  defp host_health_alert(alert), do: alert

  attr :keys, :string, required: true

  defp menu_kbd(assigns) do
    ~H"""
    <kbd class="shrink-0 rounded bg-base-200 px-1 py-density-label font-mono text-density-label text-base-content/60">
      {@keys}
    </kbd>
    """
  end

  defp menu_item_class(extra \\ nil) do
    [
      "flex w-full items-center justify-between gap-3 px-3 py-1.5 text-left text-xs",
      extra || "hover:bg-base-200"
    ]
  end

  defp notification_attention_count(assigns) do
    (assigns.notif_unread_count || 0) + (assigns.agent_approval_count || 0)
  end

  defp header_overflow_title(count) when count > 0,
    do: "More controls — #{count} agent approval#{if count == 1, do: "", else: "s"} waiting"

  defp header_overflow_title(_count), do: "More workspace and terminal controls"

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
    do: "bg-status-ok"

  def workspace_status_dot_class(status) when status in [:stopped, :error, "stopped", "error"],
    do: "bg-base-content/35"

  def workspace_status_dot_class(_status), do: "bg-status-warning"

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
