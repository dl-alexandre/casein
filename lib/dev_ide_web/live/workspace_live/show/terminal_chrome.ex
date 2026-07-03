defmodule DevIdeWeb.WorkspaceLive.Show.TerminalChrome do
  @moduledoc """
  Terminal chrome for the workspace cockpit: raw terminal surface and
  tmux pane geometry overlay, plus the pane/window/session presentation
  helpers shared with `DevIdeWeb.WorkspaceLive.Show` (raw terminal panes)
  and `DevIdeWeb.WorkspaceLive.Show.SessionBarVM` (session/window tab
  view-models). The session/window bar markup itself lives in
  `DevIdeWeb.WorkspaceLive.Show.SessionBar`.
  """

  use DevIdeWeb, :html

  import DevIdeWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  alias DevIDE.Terminals
  alias DevIDE.Terminals.PaneState

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

  def renderable_tmux_window_panes(panes) when is_list(panes) do
    bounds = tmux_pane_bounds(panes)

    case zoomed_tmux_pane(panes) do
      nil -> panes
      pane -> [Map.merge(pane, %{left: 0, top: 0, width: bounds.width, height: bounds.height})]
    end
  end

  def renderable_tmux_window_panes(_), do: []

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
    base = "#{path} · #{pane_command_label(pane)}"

    case pane_title_label(pane) do
      nil -> base
      summary -> "#{summary} · #{base}"
    end
  end

  @doc """
  Application-set pane title (OSC 0/2, e.g. Claude Code's live task summary)
  as a picker label, or nil when it adds nothing over the path fallback.
  """
  def pane_title_label(pane) when is_map(pane) do
    summary =
      case PaneState.map_get(pane, :task_summary) do
        summary when is_binary(summary) and summary != "" ->
          summary

        _ ->
          PaneState.task_summary(PaneState.map_get(pane, :pane_title))
      end

    case blank_to_nil(summary) do
      nil -> nil
      summary -> if summary == pane_path_label(pane), do: nil, else: summary
    end
  end

  def pane_title_label(_pane), do: nil

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

  @doc """
  Picks which tmux pane tile should host the Ghostty surface.

  Pane selection changes tmux focus for normal operator panes, so the web
  terminal follows the tmux-active operator pane. Preview panes may become
  tmux-active without pulling Ghostty over.
  """
  def terminal_surface_pane_id(panes, preview_panes, active_pane_id, previous_id \\ nil) do
    preview_panes = preview_panes || %{}

    cond do
      is_binary(active_pane_id) and active_pane_id != "" and
          operator_pane?(panes, preview_panes, active_pane_id) ->
        active_pane_id

      operator_pane?(panes, preview_panes, previous_id) ->
        previous_id

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

  attr :workspace, :any, required: true
  attr :workspace_start_error, :string, default: nil
  attr :focused_pane_id, :any, default: nil
  attr :pane_data, :map, default: %{}
  attr :terminal_themes, :any, default: nil

  def raw_terminal_surface(assigns) do
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
          render_authority={:worker}
          terminal_themes={@terminal_themes}
          class="h-full w-full font-mono text-sm text-zinc-100"
        />
      <% @raw_pane[:error] -> %>
        <div
          class="flex h-full w-full flex-col items-center justify-center text-center text-xs text-red-400 p-2"
          role="alert"
        >
          <.icon name="hero-exclamation-triangle" class="size-5 mb-1 text-red-500" />
          <div class="font-semibold">{raw_pane_error_title(@raw_pane[:error])}</div>
          <div class="mt-1 max-w-xs text-[11px] leading-5 text-red-200/70">
            {raw_pane_error_message(@raw_pane[:error])}
          </div>
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

  defp workspace_startable?(%{status: status}, nil),
    do: status in [:stopped, :error, "stopped", "error"]

  defp workspace_startable?(_workspace, _start_error), do: false

  defp workspace_start_blocked?(error), do: is_binary(error) and error != ""

  defp workspace_blocked_message(error) when is_binary(error) and error != "", do: error

  defp workspace_blocked_message(_error),
    do: "Start the workspace, then retry the terminal once the container is running."

  defp raw_pane_error_title(:session_ended), do: "Terminal session ended"
  defp raw_pane_error_title(:raw_start_timeout), do: "Terminal did not finish starting"
  defp raw_pane_error_title(_reason), do: "Terminal failed to start"

  defp raw_pane_error_message(:session_ended),
    do: "The selected tmux session is gone. Retry to open a fresh shell."

  defp raw_pane_error_message(:raw_start_timeout),
    do: "The terminal worker did not attach in time. Retry to start it again."

  defp raw_pane_error_message(_reason),
    do: "Retry to start the terminal again."

  defp workspace_terminal_blocked?(%{status: status}),
    do: status in [:deleting, :error, "deleting", "error"]

  attr :workspace, :any, required: true

  attr :active_tmux_window_panes, :list,
    required: true,
    doc: "the active window's panes (active_tmux_window_panes/1), pre-enrichment"

  attr :preview_panes, :map, default: %{}
  attr :tmux_session, :any, default: nil
  attr :ui_highlight_pane_id, :any, default: nil
  attr :tmux_active_pane_id, :any, default: nil
  attr :tmux_mutations_enabled?, :boolean, required: true
  attr :entered_preview_pane_id, :any, default: nil
  attr :terminal_surface_pane_id, :any, default: nil
  attr :pane_history, :any, default: nil
  attr :terminal_themes, :any, default: nil
  attr :focused_pane_id, :any, default: nil
  attr :pane_data, :map, default: %{}
  attr :workspace_start_error, :string, default: nil

  def tmux_pane_geometry(assigns) do
    bounds = tmux_pane_bounds(assigns.active_tmux_window_panes)
    now = unix_now()

    # Status is derived once per pane per render (the template reads it in
    # four attrs), against a single clock read.
    panes =
      assigns.active_tmux_window_panes
      |> renderable_tmux_window_panes()
      |> Enum.sort_by(& &1.index)
      |> Enum.map(fn pane ->
        pane
        |> Map.put(:status, pane_status(pane, now))
        |> Map.put(:preview_pane?, Map.has_key?(assigns.preview_panes, pane.id))
      end)

    surface_pane =
      case assigns.terminal_surface_pane_id do
        id when is_binary(id) and id != "" ->
          Enum.find(panes, &(&1.id == id))

        _ ->
          nil
      end

    assigns =
      assigns
      |> assign(:tmux_pane_bounds, bounds)
      |> assign(:active_tmux_window_panes, panes)
      |> assign(:terminal_surface_pane, surface_pane)
      |> assign(:active_tmux_session, assigns.tmux_session)

    ~H"""
    <div
      id={"tmux-pane-layout-" <> @workspace.id}
      data-active-pane-id={@ui_highlight_pane_id || @tmux_active_pane_id}
      data-bounds-cols={@tmux_pane_bounds.width}
      data-bounds-rows={@tmux_pane_bounds.height}
      data-resize-max={Terminals.tmux_resize_amount_max()}
      phx-hook="TmuxPaneResize"
      class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950"
    >
      <%= if @terminal_surface_pane do %>
        <div
          id={"terminal-surface-" <> @workspace.id}
          data-terminal-surface="true"
          data-pane-id={@terminal_surface_pane.id}
          data-pane-rect={"#{@tmux_pane_bounds.width}x#{@tmux_pane_bounds.height}"}
          phx-hook="TerminalSurface"
          class="absolute inset-0 z-0 isolate overflow-hidden bg-zinc-950"
        >
          <div
            id={"terminal-surface-mount-" <> @workspace.id}
            phx-update="ignore"
            class="h-full min-h-0 w-full overflow-hidden"
          >
            <.raw_terminal_surface
              workspace={@workspace}
              workspace_start_error={@workspace_start_error}
              focused_pane_id={@focused_pane_id}
              pane_data={@pane_data}
              terminal_themes={@terminal_themes}
            />
          </div>
        </div>
      <% end %>
      <%= for pane <- @active_tmux_window_panes do %>
        <section
          id={"tmux-pane-" <> dom_fragment(pane.id)}
          data-pane-id={pane.id}
          data-pane-left={tmux_dimension(pane.left)}
          data-pane-top={tmux_dimension(pane.top)}
          data-pane-width={tmux_dimension(pane.width)}
          data-pane-height={tmux_dimension(pane.height)}
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
            "absolute overflow-hidden border border-zinc-900/35 transition-colors",
            if(pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id),
              do:
                "pointer-events-none z-20 after:pointer-events-none after:absolute after:inset-x-0 after:top-0 after:z-30 after:h-px after:bg-sky-500/45",
              else: "pointer-events-auto z-10 cursor-pointer hover:bg-white/[0.03]"
            ),
            if(pane.preview_pane?, do: "bg-zinc-950", else: "bg-transparent")
          ]}
          style={tmux_pane_style(pane, @tmux_pane_bounds)}
        >
          <%= if @tmux_mutations_enabled? and
                    not pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id) do %>
            <.pane_resize_handles pane_id={pane.id} />
          <% end %>
          <%= if pane.preview_pane? do %>
            <div class="absolute inset-0 z-0 bg-zinc-950" aria-hidden="true"></div>
          <% else %>
            <%= unless @terminal_surface_pane do %>
              <div class="flex h-full items-center justify-center px-3 text-center text-xs text-zinc-500">
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
      <%= for pane <- @active_tmux_window_panes, not pane.preview_pane? do %>
        <div
          class="pointer-events-none absolute z-30"
          style={tmux_pane_style(pane, @tmux_pane_bounds)}
        >
          <button
            type="button"
            id={"pane-history-open-" <> dom_fragment(pane.id)}
            phx-click="pane:history_open"
            phx-value-pane-id={pane.id}
            title="Scrollback history"
            aria-label="Open scrollback history for this pane"
            class="pointer-events-auto absolute right-1.5 top-1.5 rounded border border-zinc-700/60 bg-zinc-950/70 px-1.5 py-0.5 font-mono text-[10px] leading-none text-zinc-400 opacity-40 backdrop-blur transition hover:border-sky-400 hover:text-sky-100 hover:opacity-100"
          >
            ⇞
          </button>
        </div>
      <% end %>
      <%= for pane <- @active_tmux_window_panes,
               preview = Map.get(@preview_panes, pane.id),
               not is_nil(preview) do %>
        <div
          id={"preview-pane-" <> dom_fragment(pane.id)}
          phx-update="ignore"
          phx-hook="PreviewPaneOverlay"
          data-pane-id={pane.id}
          data-pane-rect={preview_pane_rect_json(pane, @tmux_pane_bounds)}
          data-display-url={preview.display_url}
          data-playback-mode={preview_playback_mode?(preview)}
          data-preview-tmux-session={preview_tmux_session(preview)}
          data-active-tmux-session={@active_tmux_session}
          data-preview-session-mismatch={
            to_string(preview_session_mismatch?(preview, @active_tmux_session))
          }
          data-viewport={preview_viewport_label(preview)}
          data-snapshot-mode={preview_snapshot_mode?(preview)}
          class={[
            "preview-pane-overlay isolate overflow-hidden bg-zinc-950",
            @entered_preview_pane_id == pane.id && "preview-pane-entered"
          ]}
        >
          <%= if @tmux_mutations_enabled? and
                    not pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id) do %>
            <.pane_resize_handles pane_id={pane.id} prefix="preview-pane" z_class="z-30" />
          <% end %>
          <div
            data-preview-shield
            class="pointer-events-none absolute inset-0 z-10 bg-transparent"
          >
          </div>
          <div data-preview-clip class="absolute inset-0 z-0 overflow-hidden bg-white">
            <iframe
              data-preview-iframe
              data-src={preview.display_url}
              title={preview_pane_title(preview)}
              loading="lazy"
              sandbox={preview_iframe_sandbox(preview)}
              tabindex="-1"
            />
          </div>
          <div
            data-preview-status
            class="pointer-events-none absolute inset-0 z-20 hidden items-center justify-center bg-zinc-950/78 px-4 text-center text-zinc-100 backdrop-blur-sm"
          >
            <div class="max-w-sm rounded border border-zinc-700 bg-zinc-950/90 p-3 shadow-xl">
              <div data-preview-status-title class="text-sm font-semibold">
                Preview is still loading
              </div>
              <div
                data-preview-status-detail
                class="mt-1 text-xs leading-5 text-zinc-300"
              >
              </div>
              <div class="mt-3 flex items-center justify-center gap-2">
                <button
                  type="button"
                  data-preview-reload
                  class="pointer-events-auto rounded border border-zinc-600 bg-zinc-900 px-2 py-1 text-xs font-medium text-zinc-100 transition hover:border-sky-400 hover:text-sky-100"
                >
                  Reload
                </button>
                <button
                  type="button"
                  data-preview-reopen
                  class="pointer-events-auto rounded border border-zinc-600 bg-zinc-900 px-2 py-1 text-xs font-medium text-zinc-100 transition hover:border-amber-400 hover:text-amber-100"
                >
                  Reopen
                </button>
              </div>
            </div>
          </div>
          <div class="pointer-events-none absolute right-2 top-2 z-20 flex max-w-[calc(100%-1rem)] justify-end">
            <div
              title={preview_session_title(preview, @active_tmux_session)}
              class={[
                "max-w-full truncate rounded border px-2 py-1 text-[10px] font-medium leading-none shadow-sm backdrop-blur",
                if(preview_session_mismatch?(preview, @active_tmux_session),
                  do: "border-amber-300/50 bg-amber-950/85 text-amber-100",
                  else: "border-zinc-700/70 bg-zinc-950/80 text-zinc-200"
                )
              ]}
            >
              {preview_session_label(preview, @active_tmux_session)}
            </div>
          </div>
        </div>
      <% end %>
      <%= if @pane_history do %>
        <div
          id="pane-history-modal"
          class="absolute inset-0 z-40 flex flex-col bg-zinc-950/85 backdrop-blur-sm"
          phx-window-keydown="pane:history_close"
          phx-key="escape"
        >
          <div class="flex items-center justify-between gap-3 border-b border-zinc-800 bg-zinc-950/90 px-3 py-2">
            <div class="min-w-0 truncate font-mono text-xs text-zinc-300">
              Scrollback · {@pane_history.title}
            </div>
            <button
              type="button"
              phx-click="pane:history_close"
              class="shrink-0 rounded border border-zinc-700 bg-zinc-900 px-2 py-1 text-xs font-medium text-zinc-200 transition hover:border-sky-400 hover:text-sky-100"
            >
              Close <span class="text-zinc-500">Esc</span>
            </button>
          </div>
          <div class="min-h-0 flex-1 overflow-auto p-3">
            <%= if @pane_history.term do %>
              <.live_component
                module={DevIdeWeb.GhosttyTerminalComponent}
                id={"pane-history-" <> dom_fragment(@pane_history.pane_id)}
                term={@pane_history.term}
                cols={@pane_history.cols}
                rows={@pane_history.rows}
                fit={false}
                read_only={true}
                terminal_themes={@terminal_themes}
                class="mx-auto w-max"
              />
            <% else %>
              <div class="flex h-full items-center justify-center font-mono text-xs text-zinc-500">
                Loading history…
              </div>
            <% end %>
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

  defp zoomed_tmux_pane(panes) do
    Enum.find(panes, &(Map.get(&1, :zoomed?) == true and Map.get(&1, :active) == true)) ||
      Enum.find(panes, &(Map.get(&1, :zoomed?) == true))
  end

  attr :pane_id, :string, required: true
  attr :prefix, :string, default: "tmux-pane"
  attr :z_class, :string, default: "z-20"

  def pane_resize_handles(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-drag-left-" <> dom_fragment(@pane_id)}
      data-tmux-resize-handle="true"
      data-pane-id={@pane_id}
      data-resize-axis="x"
      class={[
        "absolute inset-y-0 left-0 w-2 cursor-col-resize bg-zinc-800/20 transition hover:bg-emerald-400/45 data-[dragging=true]:bg-emerald-400/65",
        @z_class
      ]}
      title="Drag to resize pane"
      aria-hidden="true"
    >
    </div>
    <div
      id={"#{@prefix}-drag-right-" <> dom_fragment(@pane_id)}
      data-tmux-resize-handle="true"
      data-pane-id={@pane_id}
      data-resize-axis="x"
      class={[
        "absolute inset-y-0 right-0 w-2 cursor-col-resize bg-zinc-800/20 transition hover:bg-emerald-400/45 data-[dragging=true]:bg-emerald-400/65",
        @z_class
      ]}
      title="Drag to resize pane"
      aria-hidden="true"
    >
    </div>
    <div
      id={"#{@prefix}-drag-up-" <> dom_fragment(@pane_id)}
      data-tmux-resize-handle="true"
      data-pane-id={@pane_id}
      data-resize-axis="y"
      class={[
        "absolute inset-x-0 top-0 h-2 cursor-row-resize bg-zinc-800/20 transition hover:bg-emerald-400/45 data-[dragging=true]:bg-emerald-400/65",
        @z_class
      ]}
      title="Drag to resize pane"
      aria-hidden="true"
    >
    </div>
    <div
      id={"#{@prefix}-drag-down-" <> dom_fragment(@pane_id)}
      data-tmux-resize-handle="true"
      data-pane-id={@pane_id}
      data-resize-axis="y"
      class={[
        "absolute inset-x-0 bottom-0 h-2 cursor-row-resize bg-zinc-800/20 transition hover:bg-emerald-400/45 data-[dragging=true]:bg-emerald-400/65",
        @z_class
      ]}
      title="Drag to resize pane"
      aria-hidden="true"
    >
    </div>
    """
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

  # A playback recording also lives under /preview-artifacts/, but it must stay an
  # interactive iframe so the <video> controls work — only still snapshots get the
  # click-to-coordinate shield.
  def preview_snapshot_mode?(%{display_url: display_url}) when is_binary(display_url),
    do: snapshot_artifact_url?(display_url)

  def preview_snapshot_mode?(%{"display_url" => display_url}) when is_binary(display_url),
    do: snapshot_artifact_url?(display_url)

  def preview_snapshot_mode?(_), do: false

  defp snapshot_artifact_url?(url) do
    String.contains?(url, "/preview-artifacts/") and not playback_artifact_url?(url)
  end

  @doc "True when a pane is showing a recorded playback (a stored .webm/.mp4 artifact)."
  def preview_playback_mode?(%{display_url: display_url}) when is_binary(display_url),
    do: playback_artifact_url?(display_url)

  def preview_playback_mode?(%{"display_url" => display_url}) when is_binary(display_url),
    do: playback_artifact_url?(display_url)

  def preview_playback_mode?(_), do: false

  defp playback_artifact_url?(url) do
    String.contains?(url, "/preview-artifacts/") and
      (String.contains?(url, ".webm") or String.contains?(url, ".mp4") or
         String.contains?(url, "fit=playback"))
  end

  @doc """
  True when the pane is served through the reverse proxy (`/preview-proxy/...`).
  Proxied previews re-serve an external app's HTML from DevIDE's own origin, so
  they can bypass upstream frame-blocking headers.
  """
  def preview_proxied?(%{display_url: url}) when is_binary(url),
    do: String.starts_with?(url, "/preview-proxy/")

  def preview_proxied?(%{"display_url" => url}) when is_binary(url),
    do: String.starts_with?(url, "/preview-proxy/")

  def preview_proxied?(_), do: false

  @doc """
  iframe `sandbox` for a preview pane.

  Preview-proxy iframes need `allow-same-origin` because the proxy endpoint is
  authenticated by the viewer's DevIDE session cookie. The controller still
  limits upstream access to authorized workspace loopback ports.
  """
  def preview_iframe_sandbox(_preview) do
    "allow-scripts allow-same-origin allow-forms allow-popups allow-modals"
  end

  def preview_pane_title(%{display_url: url}) when is_binary(url), do: url
  def preview_pane_title(%{"display_url" => url}) when is_binary(url), do: url
  def preview_pane_title(%{url: url}) when is_binary(url), do: url
  def preview_pane_title(%{"url" => url}) when is_binary(url), do: url
  def preview_pane_title(_), do: "preview"

  @doc "Short tab-bar style label for a tmux pane row in the window picker."
  def pane_picker_label(pane, preview \\ nil, overlay_label \\ nil)

  def pane_picker_label(_pane, nil, overlay_label)
      when is_binary(overlay_label) and overlay_label != "" do
    overlay_label
  end

  def pane_picker_label(pane, nil, _overlay_label) do
    pane_title_label(pane) || "#{pane_path_label(pane)} · #{pane_command_label(pane)}"
  end

  def pane_picker_label(_pane, preview, _overlay_label) when is_map(preview) do
    case preview_tab_title(preview) do
      title when is_binary(title) and title != "" -> title
      _ -> "Preview"
    end
  end

  @doc "Tooltip for an agent conversation overlay label."
  def agent_label_title(nil), do: nil

  def agent_label_title(%{source: source, tool: tool, updated_at: updated_at}) do
    parts =
      [
        source && "source=#{source}",
        tool && "tool=#{tool}",
        updated_at && "updated=#{Calendar.strftime(updated_at, "%H:%M:%S")}"
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "Agent label", else: Enum.join(parts, " · ")
  end

  @doc "Secondary line for a tmux pane row in the window picker."
  def pane_picker_detail(pane, preview \\ nil)

  def pane_picker_detail(pane, nil) do
    pane.current_path |> blank_to_nil() |> short_path()
  end

  def pane_picker_detail(_pane, preview) when is_map(preview) do
    case preview_display_url(preview) do
      url when is_binary(url) and url != "" ->
        case URI.parse(url) do
          %URI{path: path} when is_binary(path) and path not in ["", "/"] -> path
          _ -> preview_viewport_label(preview) || url
        end

      _ ->
        preview_viewport_label(preview) || ""
    end
  end

  @doc "Tooltip/title for a tmux pane row in the window picker."
  def pane_picker_title(pane, preview \\ nil)

  def pane_picker_title(pane, nil), do: pane_full_title(pane)

  def pane_picker_title(_pane, preview) when is_map(preview) do
    [preview_tab_title(preview), preview_display_url(preview), preview_viewport_label(preview)]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  @doc "Favicon URL for a preview pane tab row (derived from the page origin)."
  def preview_favicon_url(url) when is_binary(url) and url != "" do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        "/favicon.ico"

      _ ->
        nil
    end
  end

  def preview_favicon_url(preview) when is_map(preview) do
    preview
    |> preview_display_url()
    |> case do
      url when is_binary(url) and url != "" -> preview_favicon_url(url)
      _ -> nil
    end
  end

  def preview_favicon_url(_), do: nil

  def preview_display_url(preview) when is_map(preview) do
    preview_value(preview, :display_url) || preview_value(preview, :url)
  end

  def preview_display_url(_), do: nil

  def preview_tmux_session(preview) when is_map(preview) do
    preview_value(preview, :tmux_session)
  end

  def preview_tmux_session(_), do: nil

  def preview_session_mismatch?(preview, active_tmux_session) do
    preview_session = preview_tmux_session(preview)

    is_binary(preview_session) and preview_session != "" and
      is_binary(active_tmux_session) and active_tmux_session != "" and
      preview_session != active_tmux_session
  end

  def preview_session_label(preview, active_tmux_session) do
    preview_session = preview_tmux_session(preview)

    cond do
      preview_session_mismatch?(preview, active_tmux_session) ->
        "Other session: " <> terminal_session_label(preview_session)

      is_binary(preview_session) and preview_session != "" ->
        "Session " <> terminal_session_label(preview_session)

      true ->
        "Session unknown"
    end
  end

  def preview_session_title(preview, active_tmux_session) do
    preview_session = preview_tmux_session(preview)

    [
      "Preview tmux_session=#{blank_to_nil(preview_session) || "unknown"}",
      preview_session_mismatch?(preview, active_tmux_session) &&
        "active tmux_session=#{active_tmux_session}"
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join(" · ")
  end

  defp preview_tab_title(preview) when is_map(preview) do
    case preview_value(preview, :title) do
      title when is_binary(title) and title != "" ->
        if String.starts_with?(title, "preview "), do: nil, else: title

      _ ->
        case preview_display_url(preview) do
          url when is_binary(url) and url != "" -> DevIDE.Previews.extract_title_from_url(url)
          _ -> nil
        end
    end
  end

  defp preview_value(preview, key) when is_map(preview) and is_atom(key) do
    Map.get(preview, key) || Map.get(preview, Atom.to_string(key))
  end

  defp preview_value(_preview, _key), do: nil

  def session_attach_id(%{kind: :shell, sid: sid}), do: sid
  def session_attach_id(%{id: id}), do: id

  def session_tab_label(%{kind: :shell} = info) do
    session_alias(info) || session_context_label(info) || "workspace"
  end

  def session_tab_label(info) when is_map(info) do
    session_alias(info) || session_context_label(info) || session_kind_label(Map.get(info, :kind))
  end

  # User-set display name, stored on the tmux session as `@devide_session_alias`
  # and surfaced via session metadata. Takes priority over the derived label.
  defp session_alias(%{metadata: metadata}) when is_map(metadata) do
    (Map.get(metadata, :session_alias) || Map.get(metadata, "session_alias"))
    |> blank_to_nil()
  end

  defp session_alias(_), do: nil

  def session_kind_label(:shell), do: "Shell"
  def session_kind_label(:agent), do: "Agent"

  def session_kind_label(kind) when is_atom(kind),
    do: kind |> Atom.to_string() |> String.capitalize()

  def session_kind_label(kind), do: to_string(kind)

  def session_tab_detail(%{kind: :shell, sid: sid} = info),
    do: session_tab_detail(info, shell_sid_detail(sid))

  def session_tab_detail(info) when is_map(info),
    do: session_tab_detail(info, session_identity_detail(info))

  def session_tab_detail(info, identity) when is_map(info) do
    [session_branch(info), session_agent(info), identity]
    |> Enum.map(&blank_to_nil/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.join(" · ")
  end

  def session_tab_title(%{kind: :shell, sid: sid} = info) when is_binary(sid),
    do: session_title_with_cwd(shell_tab_title(sid), info)

  def session_tab_title(%{kind: :shell} = info),
    do: session_title_with_cwd("Workspace shell", info)

  def session_tab_title(%{kind: kind} = info),
    do: session_title_with_cwd("Terminal session " <> session_kind_label(kind), info)

  def shorten(nil), do: ""

  def shorten(s) when is_binary(s) do
    if String.length(s) > 18, do: String.slice(s, 0, 15) <> "…", else: s
  end

  def shell_sid_detail(sid) when is_binary(sid) do
    case Terminals.shell_family(sid) do
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
      [_, _ | _] = parts -> List.last(parts)
      _ -> nil
    end
  end

  defp tmux_sid(_), do: nil

  defp session_identity_detail(%{kind: :shell, sid: sid}), do: shell_sid_detail(sid)

  defp session_identity_detail(%{runner_id: runner}) when is_binary(runner),
    do: shorten(runner)

  defp session_identity_detail(_session), do: ""

  defp session_title_with_cwd(base, info) when is_map(info) do
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

  defp session_cwd(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :cwd) || Map.get(metadata, "cwd")
  end

  defp session_cwd(_), do: nil

  defp session_branch(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :git_branch) || Map.get(metadata, "git_branch")
  end

  defp session_branch(_), do: nil

  defp session_agent(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :agent) || Map.get(metadata, "agent")
  end

  defp session_agent(_), do: nil

  defp session_git_toplevel(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :git_toplevel) || Map.get(metadata, "git_toplevel")
  end

  defp session_git_toplevel(_), do: nil

  defp session_context_label(info) when is_map(info) do
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
