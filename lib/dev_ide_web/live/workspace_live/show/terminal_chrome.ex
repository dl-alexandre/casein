defmodule DevIdeWeb.WorkspaceLive.Show.TerminalChrome do
  @moduledoc """
  Terminal chrome for the workspace cockpit: governed-terminal surface and
  tmux pane geometry overlay, plus the pane/window/session presentation
  helpers shared with `DevIdeWeb.WorkspaceLive.Show` (raw terminal panes)
  and `DevIdeWeb.WorkspaceLive.Show.SessionBarVM` (session/window tab
  view-models). The session/window bar markup itself lives in
  `DevIdeWeb.WorkspaceLive.Show.SessionBar`.
  """

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  alias DevIDE.Terminals.Session.Info, as: SessionInfo
  alias DevIDE.Terminals.SessionDirectory.Compose, as: SessionCompose
  alias DevIDE.Terminals.Tmux

  @window_activity_fresh_seconds 30
  @window_activity_recent_seconds 300

  def active_tmux_window_panes(windows) when is_list(windows) do
    windows
    |> Enum.find(& &1.active)
    |> case do
      %{pane_list: panes} when is_list(panes) -> panes
      _ -> []
    end
  end

  def active_tmux_window_panes(_), do: []

  def tmux_geometry_ready?(panes) when is_list(panes) do
    length(panes) > 1 and tmux_pane_surface_ready?(panes)
  end

  # Raw mode uses the tmux pane surface for a single pane too so split only
  # adds tiles — Ghostty stays under #tmux-pane-* for the full session.
  def tmux_pane_surface_ready?(panes) when is_list(panes) do
    panes != [] and Enum.any?(panes, & &1.active) and
      Enum.all?(panes, &tmux_pane_geometry_ready?/1)
  end

  def tmux_pane_surface?(assigns) do
    assigns.tmux_windows
    |> active_tmux_window_panes()
    |> tmux_pane_surface_ready?()
  end

  def tmux_pane_geometry_ready?(pane) do
    tmux_dimension(pane.width) > 0 and tmux_dimension(pane.height) > 0
  end

  def tmux_pane_bounds(panes) do
    Enum.reduce(panes, %{left: 0, top: 0, width: 1, height: 1}, fn pane, bounds ->
      right = tmux_dimension(pane.left) + tmux_dimension(pane.width)
      bottom = tmux_dimension(pane.top) + tmux_dimension(pane.height)

      %{
        left: 0,
        top: 0,
        width: max(bounds.width, right),
        height: max(bounds.height, bottom)
      }
    end)
  end

  def tmux_pane_style(pane, bounds) do
    left = percentage(tmux_dimension(pane.left), bounds.width)
    top = percentage(tmux_dimension(pane.top), bounds.height)
    width = percentage(tmux_dimension(pane.width), bounds.width)
    height = percentage(tmux_dimension(pane.height), bounds.height)

    "left: #{left}%; top: #{top}%; width: #{width}%; height: #{height}%;"
  end

  def tmux_dimension(value) when is_integer(value), do: max(value, 0)
  def tmux_dimension(_), do: 0

  def percentage(_value, 0), do: 0

  def percentage(value, total) do
    Float.round(value / total * 100, 4)
  end

  def window_activity_state(window, now \\ unix_now()) do
    case activity_age_seconds(Map.get(window, :activity), now) do
      {:ok, age} when age < @window_activity_fresh_seconds -> :fresh
      {:ok, age} when age < @window_activity_recent_seconds -> :recent
      _ -> :idle
    end
  end

  # Render-path callers must compute `now` once and thread it through —
  # calling the clock per pane/per helper made render output a function of
  # wall-time and cost several syscalls per pane per render.
  def activity_age_seconds(activity, now \\ unix_now()) do
    with {:ok, timestamp} <- parse_activity_timestamp(activity),
         true <- timestamp > 0 do
      {:ok, max(now - timestamp, 0)}
    else
      _ -> :error
    end
  end

  def unix_now, do: System.system_time(:second)

  def parse_activity_timestamp(value) when is_integer(value), do: {:ok, value}

  def parse_activity_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {timestamp, ""} -> {:ok, timestamp}
      _ -> :error
    end
  end

  def parse_activity_timestamp(_), do: :error

  def window_activity_class(:fresh),
    do: "bg-emerald-400 shadow-[0_0_0_3px_rgba(52,211,153,0.18)]"

  def window_activity_class(:recent), do: "bg-amber-300"
  def window_activity_class(:idle), do: "bg-base-content/20"

  def window_activity_label(:fresh), do: "Recent tmux window activity"
  def window_activity_label(:recent), do: "Tmux window activity in the last five minutes"
  def window_activity_label(:idle), do: "No recent tmux window activity"

  def pane_ui_active?(pane, highlight_pane_id, tmux_active_pane_id \\ nil) do
    active_id =
      if is_binary(highlight_pane_id) and highlight_pane_id != "" do
        highlight_pane_id
      else
        tmux_active_pane_id
      end

    is_binary(active_id) and active_id != "" and pane.id == active_id
  end

  def pane_status(pane, now \\ unix_now()) do
    activity_state = pane_activity_state(pane, now)

    cond do
      Map.get(pane, :bell) -> :bell
      pane.active -> :active
      Map.get(pane, :activity_flag) -> :fresh
      activity_state in [:fresh, :recent] -> activity_state
      tmux_pane_geometry_ready?(pane) -> :alive
      true -> :unknown
    end
  end

  def pane_status_class(:active), do: "bg-primary shadow-[0_0_0_3px_rgba(14,165,233,0.18)]"

  def pane_status_class(:bell),
    do: "animate-pulse bg-rose-400 shadow-[0_0_0_3px_rgba(251,113,133,0.22)]"

  def pane_status_class(:fresh), do: "bg-emerald-400 shadow-[0_0_0_3px_rgba(52,211,153,0.18)]"
  def pane_status_class(:recent), do: "bg-amber-300"
  def pane_status_class(:alive), do: "bg-emerald-400/80"
  def pane_status_class(:unknown), do: "bg-amber-300"

  def pane_status_label(:active), do: "Active tmux pane"
  def pane_status_label(:bell), do: "Tmux pane bell alert"
  def pane_status_label(:fresh), do: "Recent tmux pane activity"
  def pane_status_label(:recent), do: "Tmux pane activity in the last five minutes"
  def pane_status_label(:alive), do: "Tmux pane ready"
  def pane_status_label(:unknown), do: "Tmux pane geometry unavailable"

  def pane_activity_state(pane, now \\ unix_now()) do
    case activity_age_seconds(Map.get(pane, :activity), now) do
      {:ok, age} when age < @window_activity_fresh_seconds -> :fresh
      {:ok, age} when age < @window_activity_recent_seconds -> :recent
      _ -> :idle
    end
  end

  def pane_bell?(pane), do: Map.get(pane, :bell, false) == true

  def pane_display_title(pane) do
    "#{pane_path_label(pane)} · #{pane_command_label(pane)}"
  end

  def pane_full_title(pane) do
    path = pane.current_path |> blank_to_nil() || "unknown path"

    "#{path} · #{pane_command_label(pane)}"
  end

  def window_full_title(window, highlight_pane_id \\ nil) do
    pane =
      cond do
        is_binary(highlight_pane_id) and highlight_pane_id != "" ->
          Enum.find(Map.get(window, :pane_list, []), &(&1.id == highlight_pane_id))

        true ->
          nil
      end

    pane = pane || Enum.find(Map.get(window, :pane_list, []), & &1.active)

    case pane do
      nil -> window.name
      pane -> "#{window.name} · #{pane_full_title(pane)}"
    end
  end

  def pane_path_label(pane) do
    pane.current_path
    |> blank_to_nil()
    |> case do
      nil ->
        "unknown"

      path ->
        blank_to_nil(Path.basename(path)) || "unknown"
    end
  end

  def pane_command_label(pane) do
    pane.current_command |> blank_to_nil() || "shell"
  end

  def blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def blank_to_nil(_), do: nil

  def short_path(nil), do: ""
  def short_path(""), do: ""

  def short_path(path) when is_binary(path) do
    home = System.get_env("HOME") || ""

    path =
      if home != "" and String.starts_with?(path, home) do
        "~" <> String.replace_prefix(path, home, "")
      else
        path
      end

    parts = String.split(path, "/", trim: true)

    case parts do
      [] -> path
      [only] -> only
      _ -> Enum.take(parts, -2) |> Enum.join("/")
    end
  end

  def assign_tmux_pane_geometry(assigns) do
    panes = active_tmux_window_panes(assigns.tmux_windows)

    assigns
    |> assign(:active_tmux_window_panes, panes)
    |> assign(:tmux_geometry_ready?, tmux_geometry_ready?(panes))
  end

  @doc """
  Picks which tmux pane tile should host the Ghostty surface.

  Pane selection only changes tmux focus and tile chrome — the web terminal
  stays on the sticky operator pane until that pane closes or the session
  resets. Preview panes may become tmux-active without pulling Ghostty over.
  """
  def terminal_surface_pane_id(panes, preview_panes, active_pane_id, previous_id \\ nil) do
    preview_panes = preview_panes || %{}

    cond do
      operator_pane?(panes, preview_panes, previous_id) ->
        previous_id

      is_binary(active_pane_id) and active_pane_id != "" and
          operator_pane?(panes, preview_panes, active_pane_id) ->
        active_pane_id

      true ->
        fallback_operator_pane_id(panes, preview_panes)
    end
  end

  defp preview_pane?(preview_panes, pane_id) when is_binary(pane_id),
    do: Map.has_key?(preview_panes, pane_id)

  defp preview_pane?(_preview_panes, _pane_id), do: false

  defp operator_pane?(panes, preview_panes, pane_id) do
    is_binary(pane_id) and pane_id != "" and
      Enum.any?(panes, &(&1.id == pane_id)) and
      not preview_pane?(preview_panes, pane_id)
  end

  defp fallback_operator_pane_id(panes, preview_panes) do
    panes
    |> Enum.reject(&preview_pane?(preview_panes, &1.id))
    |> Enum.find(& &1.active)
    |> case do
      %{id: id} ->
        id

      _ ->
        panes
        |> Enum.reject(&preview_pane?(preview_panes, &1.id))
        |> List.first()
        |> then(fn
          %{id: id} -> id
          _ -> nil
        end)
    end
  end

  def tmux_multi_pane_geometry?(assigns) do
    assigns.tmux_windows
    |> active_tmux_window_panes()
    |> tmux_geometry_ready?()
  end

  def render_governed_terminal(assigns) do
    assigns = assign_tmux_pane_geometry(assigns)

    ~H"""
    <%= if @tmux_geometry_ready? and
              (@active_session_kind != :shell or
                 not raw_terminal_available?(@workspace_mode, @host_id)) do %>
      {render_tmux_pane_geometry(assigns)}
    <% else %>
      {render_governed_terminal_surface(assigns)}
    <% end %>
    """
  end

  def render_governed_terminal_surface(assigns) do
    ~H"""
    <div
      id={"terminal-" <> @workspace.id <> "-" <> @terminal_sid <> "-governed"}
      phx-hook="GhosttyGovernedTerminal"
      phx-update="ignore"
      data-workspace-id={@workspace.id}
      data-sid={@terminal_sid}
      data-raw-session-sid={focused_pane_session_sid(@pane_data, @focused_pane_id, @terminal_sid)}
      data-active-tmux-session={@tmux_session}
      data-terminal-mode={@terminal_mode}
      data-capability-sid={@terminal_sid}
      data-host-id={@host_id}
      data-socket-token={@socket_token}
      data-terminal-capability={@terminal_workspace_capability}
      data-terminal-themes={Jason.encode!(@terminal_themes)}
      class="h-full min-h-0 w-full flex-1"
    >
    </div>
    """
  end

  def render_active_terminal_surface(assigns) do
    if assigns.terminal_mode in [:raw, :raw_ghostty] do
      render_raw_terminal_surface(assigns)
    else
      render_governed_terminal_surface(assigns)
    end
  end

  def render_raw_terminal_surface(assigns) do
    pane_id = assigns.focused_pane_id
    pane = Map.get(assigns.pane_data, pane_id, %{})

    assigns =
      assigns
      |> assign(:raw_pane_id, pane_id)
      |> assign(:raw_pane, pane)

    ~H"""
    <%= cond do %>
      <% workspace_terminal_blocked?(@workspace) -> %>
        <div
          class="flex h-full w-full flex-col items-center justify-center text-center text-xs text-amber-300 p-4"
          role="status"
        >
          <.icon name="hero-power" class="size-5 mb-2 text-amber-400" />
          <div class="font-semibold">Workspace is {@workspace.status}</div>
          <div class="mt-1 max-w-xs text-[11px] leading-5 text-amber-100/70">
            {workspace_blocked_message(@workspace_start_error)}
          </div>
          <button
            :if={workspace_startable?(@workspace, @workspace_start_error)}
            id="terminal-workspace-start-button"
            type="button"
            phx-click="workspace:start"
            class="mt-3 rounded border border-amber-400/40 bg-amber-400/10 px-3 py-1 text-[11px] font-semibold text-amber-200 hover:bg-amber-400/20 active:bg-amber-400/30 transition-colors"
          >
            Start workspace
          </button>
          <.link
            :if={workspace_start_blocked?(@workspace_start_error)}
            id="terminal-workspace-start-unavailable"
            navigate={~p"/workspaces"}
            class="mt-3 rounded border border-amber-400/30 bg-amber-400/10 px-3 py-1 text-[11px] font-semibold text-amber-100/80 transition-colors hover:bg-amber-400/20 active:bg-amber-400/30"
          >
            Open workspace card
          </.link>
        </div>
      <% is_pid(@raw_pane[:ghostty_term]) -> %>
        <.live_component
          module={DevIdeWeb.GhosttyTerminalComponent}
          id={"ghostty-" <> @raw_pane_id}
          term={@raw_pane.ghostty_term}
          pty={@raw_pane.ghostty_pty}
          fit={true}
          autofocus={false}
          terminal_themes={@terminal_themes}
          class="h-full w-full font-mono text-sm text-zinc-100"
        />
      <% @raw_pane[:error] -> %>
        <div
          class="flex h-full w-full flex-col items-center justify-center text-center text-xs text-red-400 p-2"
          role="alert"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 mb-1 text-red-500" />
          <div class="font-semibold">Terminal failed to start</div>
          <button
            type="button"
            phx-click="retry_pane"
            phx-value-pane-id={@raw_pane_id}
            class="mt-2 rounded border border-red-500/30 bg-red-500/10 px-2 py-0.5 text-[10px] text-red-300 hover:bg-red-500/20 active:bg-red-500/30 transition-colors"
          >
            Retry
          </button>
        </div>
      <% true -> %>
        <div class="flex h-full w-full items-center justify-center text-xs text-zinc-500">
          starting terminal…
        </div>
    <% end %>
    """
  end

  defp raw_terminal_available?(mode, host_id),
    do: DevIDE.Terminals.ModePolicy.raw_terminal_allowed?(mode, host_id)

  defp workspace_startable?(%{status: status}, nil),
    do: status in [:stopped, :error, "stopped", "error"]

  defp workspace_startable?(_workspace, _start_error), do: false

  defp workspace_start_blocked?(error), do: is_binary(error) and error != ""

  defp workspace_blocked_message(error) when is_binary(error) and error != "", do: error

  defp workspace_blocked_message(_error),
    do: "Start the workspace, then retry the terminal once the container is running."

  defp workspace_terminal_blocked?(%{status: status}),
    do: status in [:deleting, :error, "deleting", "error"]

  def render_tmux_pane_geometry(assigns) do
    bounds = tmux_pane_bounds(assigns.active_tmux_window_panes)
    now = unix_now()

    # Status is derived once per pane per render (the template reads it in
    # four attrs), against a single clock read.
    panes =
      assigns.active_tmux_window_panes
      |> Enum.sort_by(& &1.index)
      |> Enum.map(&Map.put(&1, :status, pane_status(&1, now)))

    assigns =
      assigns
      |> assign(:tmux_pane_bounds, bounds)
      |> assign(:active_tmux_window_panes, panes)

    ~H"""
    <div
      id={"tmux-pane-layout-" <> @workspace.id}
      data-active-pane-id={@ui_highlight_pane_id || @tmux_active_pane_id}
      data-bounds-cols={@tmux_pane_bounds.width}
      data-bounds-rows={@tmux_pane_bounds.height}
      data-resize-max={Tmux.resize_amount_max()}
      phx-hook="TmuxPaneResize"
      class="relative min-h-0 flex-1 overflow-hidden rounded border border-base-300 bg-zinc-950"
    >
      <%= for pane <- @active_tmux_window_panes do %>
        <section
          id={"tmux-pane-" <> dom_fragment(pane.id)}
          data-pane-id={pane.id}
          data-pane-index={pane.index}
          data-window-id={pane.window_id}
          data-pane-active={
            to_string(pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id))
          }
          phx-click={
            if(pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id),
              do: nil,
              else: "tmux:select_pane"
            )
          }
          phx-value-pane-id={pane.id}
          title={pane_full_title(pane)}
          class={[
            "absolute overflow-hidden border border-zinc-800 bg-zinc-950 transition-colors",
            if(pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id),
              do: "z-10 border-primary/70 shadow-[inset_0_0_0_1px_rgba(14,165,233,0.55)]",
              else: "z-0 cursor-pointer hover:border-zinc-600"
            )
          ]}
          style={tmux_pane_style(pane, @tmux_pane_bounds)}
        >
          <div class="pointer-events-none absolute inset-x-0 top-0 z-20 flex h-6 items-center gap-1 border-b border-zinc-800 bg-zinc-900/95 px-2 text-[10px] text-zinc-400">
            <span class="font-mono text-zinc-500">{pane.index}</span>
            <%!-- No raw activity timestamp here: rendering it produced a DOM
                 diff for every pane on every topology poll while output was
                 flowing. The bucketed status covers the UI; nothing in JS
                 read the raw value. --%>
            <span
              id={"tmux-pane-status-" <> dom_fragment(pane.id)}
              data-pane-status={pane.status}
              data-pane-bell={to_string(pane_bell?(pane))}
              class={[
                "size-1.5 shrink-0 rounded-full",
                pane_status_class(pane.status)
              ]}
              title={pane_status_label(pane.status)}
              aria-label={pane_status_label(pane.status)}
            ></span>
            <span
              id={"tmux-pane-title-" <> dom_fragment(pane.id)}
              class="min-w-0 truncate font-mono text-zinc-200"
            >
              <%= if preview = Map.get(@preview_panes || %{}, pane.id) do %>
                <span class="text-sky-300">{preview_pane_title(preview)}</span>
                <%= if label = preview_viewport_label(preview) do %>
                  <span class="ml-1 rounded bg-sky-500/20 px-1 text-[9px] text-sky-200">
                    {label}
                  </span>
                <% end %>
              <% else %>
                {pane_display_title(pane)}
              <% end %>
            </span>
            <span class="ml-auto min-w-0 truncate font-mono text-zinc-500">
              {short_path(pane.current_path)}
            </span>
          </div>
          <%= if @tmux_mutations_enabled? and
                    not pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id) do %>
            <div
              id={"tmux-pane-drag-left-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="x"
              class="absolute inset-y-6 left-0 z-20 w-1 cursor-col-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <div
              id={"tmux-pane-drag-right-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="x"
              class="absolute inset-y-6 right-0 z-20 w-1 cursor-col-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <div
              id={"tmux-pane-drag-up-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="y"
              class="absolute inset-x-0 top-6 z-20 h-1 cursor-row-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <div
              id={"tmux-pane-drag-down-" <> dom_fragment(pane.id)}
              data-tmux-resize-handle="true"
              data-pane-id={pane.id}
              data-resize-axis="y"
              class="absolute inset-x-0 bottom-0 z-20 h-1 cursor-row-resize bg-transparent transition hover:bg-emerald-400/50 data-[dragging=true]:bg-emerald-400/70"
              title="Drag to resize pane"
              aria-hidden="true"
            >
            </div>
            <button
              type="button"
              id={"tmux-pane-kill-" <> dom_fragment(pane.id)}
              phx-click="tmux:kill_pane"
              phx-value-pane-id={pane.id}
              class="absolute right-1 top-1 z-30 rounded p-1 text-zinc-500 transition hover:bg-red-500/15 hover:text-red-300"
              title="Close tmux pane"
              aria-label="Close tmux pane"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
            <div class="absolute left-1 top-7 z-30 grid grid-cols-3 gap-0.5">
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-up-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="up"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane up"
                aria-label="Resize pane up"
              >
                <.icon name="hero-arrow-up" class="size-3" />
              </button>
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-left-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="left"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane left"
                aria-label="Resize pane left"
              >
                <.icon name="hero-arrow-left" class="size-3" />
              </button>
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-right-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="right"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane right"
                aria-label="Resize pane right"
              >
                <.icon name="hero-arrow-right" class="size-3" />
              </button>
              <span></span>
              <button
                type="button"
                id={"tmux-pane-resize-down-" <> dom_fragment(pane.id)}
                phx-click="tmux:resize_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="down"
                phx-value-amount="5"
                class="rounded p-1 text-zinc-500 transition hover:bg-emerald-500/15 hover:text-emerald-300"
                title="Resize pane down"
                aria-label="Resize pane down"
              >
                <.icon name="hero-arrow-down" class="size-3" />
              </button>
              <span></span>
            </div>
            <div class="absolute right-1 top-7 z-30 flex flex-col gap-1">
              <button
                type="button"
                id={"tmux-pane-split-h-" <> dom_fragment(pane.id)}
                phx-click="tmux:split_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="h"
                class="rounded p-1 text-zinc-500 transition hover:bg-sky-500/15 hover:text-sky-300"
                title="Split pane left/right"
                aria-label="Split pane left/right"
              >
                <.split_icon direction={:right} class="size-3.5" />
              </button>
              <button
                type="button"
                id={"tmux-pane-split-v-" <> dom_fragment(pane.id)}
                phx-click="tmux:split_pane"
                phx-value-pane-id={pane.id}
                phx-value-direction="v"
                class="rounded p-1 text-zinc-500 transition hover:bg-sky-500/15 hover:text-sky-300"
                title="Split pane top/bottom"
                aria-label="Split pane top/bottom"
              >
                <.split_icon direction={:down} class="size-3.5" />
              </button>
            </div>
          <% end %>
          <%= if pane.id == @terminal_surface_pane_id do %>
            <div
              id={"terminal-surface-" <> dom_fragment(pane.id)}
              data-terminal-surface="true"
              data-pane-id={pane.id}
              class="absolute inset-0 isolate overflow-hidden bg-zinc-950 pt-6"
            >
              <div
                id={"terminal-surface-mount-" <> @workspace.id}
                phx-update="ignore"
                class="h-full min-h-0 w-full overflow-hidden"
              >
                {render_active_terminal_surface(assigns)}
              </div>
            </div>
          <% else %>
            <%= if Map.has_key?(@preview_panes || %{}, pane.id) do %>
              <div class="absolute inset-0 z-0 bg-zinc-950 pt-6" aria-hidden="true"></div>
            <% else %>
              <div class="flex h-full items-center justify-center px-3 pt-6 text-center text-xs text-zinc-500">
                <div class="min-w-0">
                  <div class="truncate font-mono text-zinc-300">{pane_display_title(pane)}</div>
                  <div class="mt-1 truncate font-mono text-[10px]">
                    {short_path(pane.current_path)}
                  </div>
                </div>
              </div>
            <% end %>
          <% end %>
        </section>
      <% end %>
      <%= for pane <- @active_tmux_window_panes,
               preview = Map.get(@preview_panes || %{}, pane.id),
               not is_nil(preview) do %>
        <div
          id={"preview-pane-" <> dom_fragment(pane.id)}
          phx-update="ignore"
          phx-hook="PreviewPaneOverlay"
          data-pane-id={pane.id}
          data-pane-rect={preview_pane_rect_json(pane, @tmux_pane_bounds)}
          data-display-url={preview.display_url}
          data-viewport={preview_viewport_label(preview)}
          class={[
            "preview-pane-overlay bg-zinc-950",
            @entered_preview_pane_id == pane.id && "preview-pane-entered ring-2 ring-sky-400/80"
          ]}
        >
          <div
            data-preview-shield
            class="absolute inset-0 z-10 cursor-pointer bg-zinc-950/95"
            title="Click to select pane · double-click to enter preview"
          >
          </div>
          <div data-preview-clip class="absolute inset-0 z-0 overflow-hidden pt-6">
            <iframe
              data-preview-iframe
              src={preview.display_url}
              title={preview_pane_title(preview)}
              loading="lazy"
              sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-modals"
              tabindex="-1"
            />
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  def preview_pane_rect_json(pane, bounds) do
    %{
      left: percentage(tmux_dimension(pane.left), bounds.width),
      top: percentage(tmux_dimension(pane.top), bounds.height),
      width: percentage(tmux_dimension(pane.width), bounds.width),
      height: percentage(tmux_dimension(pane.height), bounds.height)
    }
    |> Jason.encode!()
  end

  def preview_viewport_label(%{viewport: %{width: width, height: height}})
      when is_integer(width) and is_integer(height),
      do: "#{width}x#{height}"

  def preview_viewport_label(%{"viewport" => %{"width" => width, "height" => height}})
      when is_integer(width) and is_integer(height),
      do: "#{width}x#{height}"

  def preview_viewport_label(%{viewport: viewport}) when is_binary(viewport), do: viewport
  def preview_viewport_label(%{"viewport" => viewport}) when is_binary(viewport), do: viewport
  def preview_viewport_label(_), do: nil

  def preview_pane_title(%{display_url: url}) when is_binary(url), do: url
  def preview_pane_title(%{"display_url" => url}) when is_binary(url), do: url
  def preview_pane_title(%{url: url}) when is_binary(url), do: url
  def preview_pane_title(%{"url" => url}) when is_binary(url), do: url
  def preview_pane_title(_), do: "preview"

  def session_attach_id(%SessionInfo{kind: :shell, sid: sid}), do: sid
  def session_attach_id(%SessionInfo{id: id}), do: id

  def session_tab_label(%SessionInfo{kind: :shell} = info) do
    session_context_label(info) || "workspace"
  end

  def session_tab_label(%SessionInfo{} = info) do
    session_context_label(info) || session_kind_label(info.kind)
  end

  def session_kind_label(:shell), do: "Shell"
  def session_kind_label(:execution), do: "Exec"
  def session_kind_label(:agent), do: "Agent"

  def session_kind_label(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> String.capitalize()

  def session_kind_label(kind), do: to_string(kind)

  def session_tab_detail(%SessionInfo{kind: :shell, sid: sid} = info),
    do: session_tab_detail(info, shell_sid_detail(sid))

  def session_tab_detail(%SessionInfo{} = info),
    do: session_tab_detail(info, session_identity_detail(info))

  def session_tab_detail(%SessionInfo{} = info, identity) do
    [session_branch(info), session_agent(info), identity]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  def session_tab_title(%SessionInfo{kind: :execution, execution_id: id} = info)
      when is_binary(id),
      do: session_title_with_cwd("Fleet execution " <> id, info)

  def session_tab_title(%SessionInfo{kind: :execution} = info),
    do: session_title_with_cwd("Fleet execution", info)

  def session_tab_title(%SessionInfo{kind: :shell, sid: sid} = info) when is_binary(sid),
    do: session_title_with_cwd(shell_tab_title(sid), info)

  def session_tab_title(%SessionInfo{kind: :shell} = info),
    do: session_title_with_cwd("Workspace shell", info)

  def session_tab_title(%SessionInfo{kind: kind} = info),
    do: session_title_with_cwd("Terminal session " <> session_kind_label(kind), info)

  def shorten(nil), do: ""

  def shorten(s) when is_binary(s) do
    if String.length(s) > 18, do: String.slice(s, 0, 15) <> "…", else: s
  end

  def shell_sid_detail(sid) when is_binary(sid) do
    case SessionCompose.shell_family(sid) do
      family when is_binary(family) ->
        sid |> String.replace_prefix(family <> "-", "") |> shorten()

      _ ->
        shorten(sid)
    end
  end

  def shell_sid_detail(_), do: ""

  def shell_button_detail(default_sid, _active_sid, _panes) do
    shell_sid_detail(default_sid)
  end

  def shell_button_label(default_sid, active_sid, panes, host_path \\ nil) do
    cwd = if default_sid == active_sid, do: active_pane_cwd(panes)

    cwd_detail(cwd) || host_path_detail(host_path) || "workspace"
  end

  def shell_tab_title(sid) when is_binary(sid) and sid != "", do: "Workspace shell " <> sid
  def shell_tab_title(_), do: "Workspace shell"

  def terminal_session_label(tmux_session, terminal_sid \\ nil) do
    terminal_sid_label = terminal_sid |> shell_sid_detail() |> blank_to_nil()
    tmux_sid_label = tmux_session |> tmux_sid() |> shell_sid_detail() |> blank_to_nil()

    terminal_sid_label || tmux_sid_label || shorten(tmux_session)
  end

  defp tmux_sid("devide_" <> rest) do
    case String.split(rest, "_") do
      parts when length(parts) >= 2 -> List.last(parts)
      _ -> nil
    end
  end

  defp tmux_sid(_), do: nil

  defp session_identity_detail(%SessionInfo{kind: :execution, tmux_session: tmux}),
    do: shorten(tmux)

  defp session_identity_detail(%SessionInfo{kind: :shell, sid: sid}), do: shell_sid_detail(sid)

  defp session_identity_detail(%SessionInfo{runner_id: runner}) when is_binary(runner),
    do: shorten(runner)

  defp session_identity_detail(_session), do: ""

  defp session_title_with_cwd(base, %SessionInfo{} = info) do
    [
      base,
      session_cwd(info),
      session_branch(info),
      session_agent(info),
      session_identity_detail(info)
    ]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  defp session_cwd(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :cwd) || Map.get(metadata, "cwd")
  end

  defp session_cwd(_), do: nil

  defp session_branch(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :git_branch) || Map.get(metadata, "git_branch")
  end

  defp session_branch(_), do: nil

  defp session_agent(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent) || Map.get(metadata, "agent")
  end

  defp session_agent(_), do: nil

  defp session_git_toplevel(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :git_toplevel) || Map.get(metadata, "git_toplevel")
  end

  defp session_git_toplevel(_), do: nil

  defp session_context_label(%SessionInfo{} = info) do
    cwd = session_cwd(info)
    toplevel = session_git_toplevel(info)

    cond do
      is_binary(cwd) and cwd != "" and is_binary(toplevel) and toplevel != "" and
          cwd == toplevel ->
        Path.basename(toplevel)

      is_binary(cwd) and cwd != "" and is_binary(toplevel) and toplevel != "" and
          String.starts_with?(cwd, toplevel <> "/") ->
        Path.join(Path.basename(toplevel), Path.relative_to(cwd, toplevel))

      is_binary(toplevel) and toplevel != "" ->
        Path.basename(toplevel)

      is_binary(cwd) and cwd != "" ->
        short_path(cwd)

      true ->
        nil
    end
  end

  defp active_pane_cwd(panes) when is_list(panes) do
    panes
    |> Enum.find(&Map.get(&1, :active))
    |> case do
      nil -> nil
      pane -> Map.get(pane, :current_path) || Map.get(pane, "current_path")
    end
  end

  defp active_pane_cwd(_), do: nil

  defp cwd_detail(cwd) when is_binary(cwd) and cwd != "", do: short_path(cwd)
  defp cwd_detail(_), do: nil

  defp host_path_detail({:ok, path}), do: cwd_detail(path)
  defp host_path_detail(path), do: cwd_detail(path)

  # Audit raw-shell mode transitions. Entering :raw opens an unconstrained
  # PTY against the workspace; leaving it tears that PTY down. Both are
  # security-interesting boundary crossings — the snapshot button already
  def focused_pane_session_sid(pane_data, focused_pane_id, fallback_sid)
      when is_map(pane_data) do
    case Map.get(pane_data, focused_pane_id) do
      %{session_sid: sid} when is_binary(sid) and sid != "" -> sid
      _ -> fallback_sid
    end
  end

  def focused_pane_session_sid(_pane_data, _focused_pane_id, fallback_sid), do: fallback_sid
end
