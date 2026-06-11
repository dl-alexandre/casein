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
    length(panes) > 1 and Enum.any?(panes, & &1.active) and
      Enum.all?(panes, &tmux_pane_geometry_ready?/1)
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

  def window_activity_state(window) do
    case activity_age_seconds(Map.get(window, :activity)) do
      {:ok, age} when age < @window_activity_fresh_seconds -> :fresh
      {:ok, age} when age < @window_activity_recent_seconds -> :recent
      _ -> :idle
    end
  end

  def activity_age_seconds(activity) do
    with {:ok, timestamp} <- parse_activity_timestamp(activity),
         true <- timestamp > 0 do
      {:ok, max(DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(timestamp), 0)}
    else
      _ -> :error
    end
  end

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

  def pane_status(pane) do
    activity_state = pane_activity_state(pane)

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

  def pane_activity_state(pane) do
    case activity_age_seconds(Map.get(pane, :activity)) do
      {:ok, age} when age < @window_activity_fresh_seconds -> :fresh
      {:ok, age} when age < @window_activity_recent_seconds -> :recent
      _ -> :idle
    end
  end

  def pane_activity_value(pane), do: Map.get(pane, :activity, 0) || 0

  def pane_bell?(pane), do: Map.get(pane, :bell, false) == true

  def pane_display_title(pane) do
    "#{pane_path_label(pane)} · #{pane_command_label(pane)}"
  end

  def pane_full_title(pane) do
    path = pane.current_path |> blank_to_nil() || "unknown path"

    "#{path} · #{pane_command_label(pane)}"
  end

  def window_full_title(window) do
    case Enum.find(Map.get(window, :pane_list, []), & &1.active) do
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

  def render_governed_terminal(assigns) do
    panes = active_tmux_window_panes(assigns.tmux_windows)

    assigns =
      assigns
      |> assign(:active_tmux_window_panes, panes)
      |> assign(:tmux_geometry_ready?, tmux_geometry_ready?(panes))

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
      class="h-full min-h-0 w-full flex-1"
    >
    </div>
    """
  end

  defp raw_terminal_available?(mode, host_id),
    do: DevIDE.Terminals.ModePolicy.raw_terminal_allowed?(mode, host_id)

  def render_tmux_pane_geometry(assigns) do
    bounds = tmux_pane_bounds(assigns.active_tmux_window_panes)

    assigns =
      assigns
      |> assign(:tmux_pane_bounds, bounds)
      |> assign(
        :active_tmux_window_panes,
        Enum.sort_by(assigns.active_tmux_window_panes, & &1.index)
      )

    ~H"""
    <div
      id={"tmux-pane-layout-" <> @workspace.id}
      data-active-pane-id={@tmux_active_pane_id}
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
          data-window-id={pane.window_id}
          data-pane-active={to_string(pane.active)}
          phx-click={if(pane.active, do: nil, else: "tmux:select_pane")}
          phx-value-pane-id={pane.id}
          title={pane_full_title(pane)}
          class={[
            "absolute overflow-hidden border border-zinc-800 bg-zinc-950 transition-colors",
            if(pane.active,
              do: "z-10 border-primary/70 shadow-[inset_0_0_0_1px_rgba(14,165,233,0.55)]",
              else: "z-0 cursor-pointer hover:border-zinc-600"
            )
          ]}
          style={tmux_pane_style(pane, @tmux_pane_bounds)}
        >
          <div class="pointer-events-none absolute inset-x-0 top-0 z-20 flex h-6 items-center gap-1 border-b border-zinc-800 bg-zinc-900/95 px-2 text-[10px] text-zinc-400">
            <span class="font-mono text-zinc-500">{pane.index}</span>
            <span
              id={"tmux-pane-status-" <> dom_fragment(pane.id)}
              data-pane-status={pane_status(pane)}
              data-pane-activity={pane_activity_value(pane)}
              data-pane-bell={to_string(pane_bell?(pane))}
              class={[
                "size-1.5 shrink-0 rounded-full",
                pane_status_class(pane_status(pane))
              ]}
              title={pane_status_label(pane_status(pane))}
              aria-label={pane_status_label(pane_status(pane))}
            >
            </span>
            <span
              id={"tmux-pane-title-" <> dom_fragment(pane.id)}
              class="min-w-0 truncate font-mono text-zinc-200"
            >
              {pane_display_title(pane)}
            </span>
            <span class="ml-auto min-w-0 truncate font-mono text-zinc-500">
              {short_path(pane.current_path)}
            </span>
          </div>
          <%= if pane.active do %>
            <div class="absolute inset-0 pt-6">
              {render_governed_terminal_surface(assigns)}
            </div>
          <% else %>
            <%= if @tmux_mutations_enabled? do %>
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
                  <.icon name="hero-bars-3-bottom-left" class="size-3.5 rotate-90" />
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
                  <.icon name="hero-bars-3-bottom-left" class="size-3.5" />
                </button>
              </div>
            <% end %>
            <div class="flex h-full items-center justify-center px-3 pt-6 text-center text-xs text-zinc-500">
              <div class="min-w-0">
                <div class="truncate font-mono text-zinc-300">{pane_display_title(pane)}</div>
                <div class="mt-1 truncate font-mono text-[10px]">{short_path(pane.current_path)}</div>
              </div>
            </div>
          <% end %>
        </section>
      <% end %>
    </div>
    """
  end

  def session_attach_id(%SessionInfo{kind: :shell, sid: sid}), do: sid
  def session_attach_id(%SessionInfo{id: id}), do: id

  def session_kind_label(:shell), do: "Shell"
  def session_kind_label(:execution), do: "Exec"
  def session_kind_label(:agent), do: "Agent"

  def session_kind_label(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> String.capitalize()

  def session_kind_label(kind), do: to_string(kind)

  def session_tab_detail(%SessionInfo{kind: :shell, sid: sid} = info) do
    info
    |> session_cwd()
    |> cwd_detail()
    |> detail_with_identity(shell_sid_detail(sid))
  end

  def session_tab_detail(%SessionInfo{} = info) do
    case session_cwd(info) do
      cwd when is_binary(cwd) and cwd != "" -> short_path(cwd)
      _ -> session_identity_detail(info)
    end
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

  def shell_button_detail(default_sid, active_sid, panes) do
    cwd_detail =
      if default_sid == active_sid do
        panes
        |> active_pane_cwd()
        |> cwd_detail()
      end

    detail_with_identity(cwd_detail, shell_sid_detail(default_sid))
  end

  def shell_tab_title(sid) when is_binary(sid) and sid != "", do: "Workspace shell " <> sid
  def shell_tab_title(_), do: "Workspace shell"

  defp session_identity_detail(%SessionInfo{kind: :execution, tmux_session: tmux}),
    do: shorten(tmux)

  defp session_identity_detail(%SessionInfo{kind: :shell, sid: sid}), do: shell_sid_detail(sid)

  defp session_identity_detail(%SessionInfo{runner_id: runner}) when is_binary(runner),
    do: shorten(runner)

  defp session_identity_detail(_session), do: ""

  defp session_title_with_cwd(base, %SessionInfo{} = info) do
    case session_cwd(info) do
      cwd when is_binary(cwd) and cwd != "" -> base <> " · " <> cwd
      _ -> base
    end
  end

  defp session_cwd(%SessionInfo{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :cwd) || Map.get(metadata, "cwd")
  end

  defp session_cwd(_), do: nil

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

  defp detail_with_identity(detail, identity) do
    [detail, identity]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

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
