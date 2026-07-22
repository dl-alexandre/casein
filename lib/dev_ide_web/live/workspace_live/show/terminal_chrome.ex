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
  alias DevIDE.Terminals.PaneInteraction
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

  def mobile_focus_pane(panes, highlight_pane_id, tmux_active_pane_id) when is_list(panes) do
    Enum.find(panes, &pane_ui_active?(&1, highlight_pane_id, tmux_active_pane_id)) ||
      Enum.find(panes, &(Map.get(&1, :active) == true)) ||
      List.first(panes)
  end

  def mobile_focus_pane(_panes, _highlight_pane_id, _tmux_active_pane_id), do: nil

  def mobile_focus_layout_style(nil, _bounds), do: ""

  def mobile_focus_layout_style(pane, bounds) do
    left = percentage(tmux_dimension(pane.left), bounds.width)
    top = percentage(tmux_dimension(pane.top), bounds.height)
    width = percentage(tmux_dimension(pane.width), bounds.width)
    height = percentage(tmux_dimension(pane.height), bounds.height)

    # Uniform (fit) scale — never scale a terminal by different x/y factors or its
    # monospace glyphs stretch. In the normal path the active pane is tmux-zoomed
    # (see the ensure-zoom hook), so both factors are 1 and this is identity; the
    # min only matters for the brief unzoomed frame before ensure-zoom lands, where
    # a proportionate letterbox beats a stretch.
    scale =
      min(
        mobile_focus_scale(bounds.width, pane.width),
        mobile_focus_scale(bounds.height, pane.height)
      )

    [
      "--devide-mobile-pane-left: #{left}%",
      "--devide-mobile-pane-top: #{top}%",
      "--devide-mobile-pane-width: #{width}%",
      "--devide-mobile-pane-height: #{height}%",
      "--devide-mobile-pane-scale: #{scale}"
    ]
    |> Enum.join("; ")
    |> Kernel.<>(";")
  end

  def mobile_pane_rails(panes, active_pane_id) when is_list(panes) do
    active = Enum.find(panes, &(Map.get(&1, :id) == active_pane_id))

    case active do
      nil ->
        []

      active ->
        active_rect = mobile_pane_rect(active)

        panes
        |> Enum.reject(&(Map.get(&1, :id) == active_pane_id))
        |> Enum.flat_map(&mobile_pane_rail(active_rect, &1))
        |> Enum.sort_by(fn rail ->
          {mobile_pane_rail_order(rail.direction), rail.start, Map.get(rail.pane, :index, 0)}
        end)
    end
  end

  def mobile_pane_rails(_panes, _active_pane_id), do: []

  def mobile_pane_rail_style(%{direction: :left, start: start, size: size}) do
    "left: 0; top: #{start}%; height: #{size}%; width: var(--devide-mobile-pane-rail-hit);"
  end

  def mobile_pane_rail_style(%{direction: :right, start: start, size: size}) do
    "right: 0; top: #{start}%; height: #{size}%; width: var(--devide-mobile-pane-rail-hit);"
  end

  def mobile_pane_rail_style(%{direction: :top, start: start, size: size}) do
    "top: 0; left: #{start}%; width: #{size}%; height: var(--devide-mobile-pane-rail-hit);"
  end

  def mobile_pane_rail_style(%{direction: :bottom, start: start, size: size}) do
    "bottom: 0; left: #{start}%; width: #{size}%; height: var(--devide-mobile-pane-rail-hit);"
  end

  def tmux_dimension(value) when is_integer(value), do: max(value, 0)
  def tmux_dimension(_), do: 0

  def percentage(_value, 0), do: 0

  def percentage(value, total) do
    Float.round(value / total * 100, 4)
  end

  defp mobile_focus_scale(total, value) do
    total = tmux_dimension(total)
    value = tmux_dimension(value)

    if total > 0 and value > 0 do
      Float.round(total / value, 4)
    else
      1
    end
  end

  defp mobile_pane_rect(pane) do
    %{
      left: tmux_dimension(Map.get(pane, :left)),
      top: tmux_dimension(Map.get(pane, :top)),
      width: tmux_dimension(Map.get(pane, :width)),
      height: tmux_dimension(Map.get(pane, :height))
    }
  end

  defp mobile_pane_rail(active_rect, pane) do
    other_rect = mobile_pane_rect(pane)

    cond do
      mobile_pane_right(other_rect) == active_rect.left and
          mobile_pane_overlaps_y?(active_rect, other_rect) ->
        mobile_vertical_rail(:left, active_rect, other_rect, pane)

      other_rect.left == mobile_pane_right(active_rect) and
          mobile_pane_overlaps_y?(active_rect, other_rect) ->
        mobile_vertical_rail(:right, active_rect, other_rect, pane)

      mobile_pane_bottom(other_rect) == active_rect.top and
          mobile_pane_overlaps_x?(active_rect, other_rect) ->
        mobile_horizontal_rail(:top, active_rect, other_rect, pane)

      other_rect.top == mobile_pane_bottom(active_rect) and
          mobile_pane_overlaps_x?(active_rect, other_rect) ->
        mobile_horizontal_rail(:bottom, active_rect, other_rect, pane)

      true ->
        []
    end
  end

  defp mobile_vertical_rail(direction, active_rect, other_rect, pane) do
    with true <- active_rect.height > 0,
         start <- max(active_rect.top, other_rect.top),
         finish <- min(mobile_pane_bottom(active_rect), mobile_pane_bottom(other_rect)),
         true <- finish > start do
      [
        %{
          direction: direction,
          pane: pane,
          start: percentage(start - active_rect.top, active_rect.height),
          size: percentage(finish - start, active_rect.height)
        }
      ]
    else
      _ -> []
    end
  end

  defp mobile_horizontal_rail(direction, active_rect, other_rect, pane) do
    with true <- active_rect.width > 0,
         start <- max(active_rect.left, other_rect.left),
         finish <- min(mobile_pane_right(active_rect), mobile_pane_right(other_rect)),
         true <- finish > start do
      [
        %{
          direction: direction,
          pane: pane,
          start: percentage(start - active_rect.left, active_rect.width),
          size: percentage(finish - start, active_rect.width)
        }
      ]
    else
      _ -> []
    end
  end

  defp mobile_pane_overlaps_y?(a, b),
    do: a.top < mobile_pane_bottom(b) and mobile_pane_bottom(a) > b.top

  defp mobile_pane_overlaps_x?(a, b),
    do: a.left < mobile_pane_right(b) and mobile_pane_right(a) > b.left

  defp mobile_pane_right(rect), do: rect.left + rect.width
  defp mobile_pane_bottom(rect), do: rect.top + rect.height

  defp mobile_pane_rail_order(:left), do: 0
  defp mobile_pane_rail_order(:right), do: 1
  defp mobile_pane_rail_order(:top), do: 2
  defp mobile_pane_rail_order(:bottom), do: 3

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

  # Agent-launch pairing stamp (@devide_paired pane option): true/false once a
  # launcher ran in the pane, nil (attr omitted) when no agent ever launched.
  def pane_paired_attr(pane) do
    case Map.get(pane, :paired) do
      true -> "true"
      false -> "false"
      _ -> nil
    end
  end

  def pane_unpaired_title(pane) do
    case Map.get(pane, :paired_reason) do
      reason when is_binary(reason) and reason != "" ->
        "Agent launched without DevIDE MCP — #{reason}"

      _ ->
        "Agent launched without DevIDE MCP"
    end
  end

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
  Merged occupancy map of "feature panes" — tmux panes whose content is a
  web-rendered overlay (preview iframes, file-editor overlays) rather than a
  terminal. Keys are tmux pane ids. Everywhere the cockpit used to special-case
  previews for focus / UI-only selection must consult this merged map so
  Ghostty never attaches to a file holder pane either.

  `preview_panes` is the legacy `:preview_panes` assign; `feature_panes` is the
  generic `:feature_panes` assign (`%{pane_id => %{type, payload}}`), of which
  only `:file` entries are consumed here (previews stay on their legacy assign
  until the runtime cutover).
  """
  def feature_pane_map(preview_panes, feature_panes) do
    Map.merge(file_pane_entries(feature_panes), preview_panes || %{})
  end

  @doc "The `:file` entries of a `:feature_panes` assign, keyed by tmux pane id."
  def file_pane_entries(feature_panes) do
    for {pane_id, %{type: :file} = entry} <- feature_panes || %{}, into: %{} do
      {pane_id, entry}
    end
  end

  @doc "True when `pane_id` hosts a feature pane (preview OR file)."
  def feature_pane?(preview_panes, feature_panes, pane_id) when is_binary(pane_id) do
    Map.has_key?(preview_panes || %{}, pane_id) or
      match?(%{type: :file}, Map.get(feature_panes || %{}, pane_id))
  end

  def feature_pane?(_preview_panes, _feature_panes, _pane_id), do: false

  @doc """
  Picks which tmux pane tile should host the Ghostty surface.

  Pane selection changes tmux focus for normal operator panes, so the web
  terminal follows the tmux-active operator pane. Feature panes (previews and
  file editors) may become tmux-active without pulling Ghostty over —
  `occupied_panes` is the merged `feature_pane_map/2`.
  """
  def terminal_surface_pane_id(panes, occupied_panes, active_pane_id, previous_id \\ nil) do
    occupied_panes = occupied_panes || %{}

    cond do
      is_binary(active_pane_id) and active_pane_id != "" and
          operator_pane?(panes, occupied_panes, active_pane_id) ->
        active_pane_id

      operator_pane?(panes, occupied_panes, previous_id) ->
        previous_id

      true ->
        fallback_operator_pane_id(panes, occupied_panes)
    end
  end

  defp occupied_pane?(occupied_panes, pane_id) when is_binary(pane_id),
    do: Map.has_key?(occupied_panes, pane_id)

  defp occupied_pane?(_occupied_panes, _pane_id), do: false

  defp operator_pane?(panes, occupied_panes, pane_id) do
    is_binary(pane_id) and pane_id != "" and
      Enum.any?(panes, &(&1.id == pane_id)) and
      not occupied_pane?(occupied_panes, pane_id)
  end

  defp fallback_operator_pane_id(panes, occupied_panes) do
    panes
    |> Enum.reject(&occupied_pane?(occupied_panes, &1.id))
    |> Enum.find(& &1.active)
    |> case do
      %{id: id} ->
        id

      _ ->
        panes
        |> Enum.reject(&occupied_pane?(occupied_panes, &1.id))
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
            navigate={~p"/"}
            class="mt-3 rounded border border-amber-400/30 bg-amber-400/10 px-3 py-1 text-[11px] font-semibold text-amber-100/80 transition-colors hover:bg-amber-400/20 active:bg-amber-400/30"
          >
            Open home terminal
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

  attr :feature_panes, :map,
    default: %{},
    doc: "generic pane registry snapshot (%{pane_id => %{type, payload}}); only :file consumed"

  attr :tmux_session, :any, default: nil
  attr :ui_highlight_pane_id, :any, default: nil
  attr :tmux_active_pane_id, :any, default: nil
  attr :window_zoomed?, :boolean, default: false
  attr :topology_layout_version, :integer, default: 0
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

    # Full (uncollapsed) pane list for the active window. The mobile focus rails,
    # the focus-pane pick, and multi-pane detection all read this so they survive
    # tmux zoom: `renderable_tmux_window_panes/1` collapses the list to the single
    # zoomed pane for the terminal *surface*, which would otherwise erase the pane
    # rails and make a zoomed multi-pane window look like a single-pane one.
    full_panes = Enum.sort_by(assigns.active_tmux_window_panes, & &1.index)

    file_panes = file_pane_entries(assigns.feature_panes)

    # Status is derived once per pane per render (the template reads it in four
    # attrs), against a single clock read. Collapsed to the zoomed pane so only
    # that surface section renders when zoomed.
    panes =
      full_panes
      |> renderable_tmux_window_panes()
      |> Enum.map(fn pane ->
        pane
        |> Map.put(:status, pane_status(pane, now))
        |> Map.put(:preview_pane?, Map.has_key?(assigns.preview_panes, pane.id))
        |> Map.put(:file_pane?, Map.has_key?(file_panes, pane.id))
        |> then(&Map.put(&1, :feature_pane?, &1.preview_pane? or &1.file_pane?))
      end)

    surface_pane =
      case assigns.terminal_surface_pane_id do
        id when is_binary(id) and id != "" ->
          Enum.find(panes, &(&1.id == id))

        _ ->
          nil
      end

    mobile_focus_pane =
      mobile_focus_pane(full_panes, assigns.ui_highlight_pane_id, assigns.tmux_active_pane_id)

    mobile_focus_pane_id = if mobile_focus_pane, do: mobile_focus_pane.id

    assigns =
      assigns
      |> assign(:tmux_pane_bounds, bounds)
      |> assign(:file_panes, file_panes)
      |> assign(:active_tmux_window_panes, panes)
      |> assign(:mobile_multi_pane?, length(full_panes) > 1)
      |> assign(:terminal_surface_pane, surface_pane)
      |> assign(:active_tmux_session, assigns.tmux_session)
      |> assign(:mobile_focus_pane, mobile_focus_pane)
      |> assign(:mobile_focus_pane_id, mobile_focus_pane_id)
      |> assign(:mobile_pane_rails, mobile_pane_rails(full_panes, mobile_focus_pane_id))

    ~H"""
    <div
      id={"tmux-pane-layout-" <> @workspace.id}
      data-active-pane-id={@ui_highlight_pane_id || @tmux_active_pane_id}
      data-mobile-focus-layout={to_string(@mobile_multi_pane?)}
      data-mobile-focus-pane-id={@mobile_focus_pane_id}
      data-window-zoomed={to_string(@window_zoomed?)}
      data-layout-version={@topology_layout_version}
      data-bounds-cols={@tmux_pane_bounds.width}
      data-bounds-rows={@tmux_pane_bounds.height}
      data-resize-max={Terminals.tmux_resize_amount_max()}
      phx-hook="TmuxPaneResize"
      class="relative min-h-0 flex-1 overflow-hidden bg-zinc-950"
      style={mobile_focus_layout_style(@mobile_focus_pane, @tmux_pane_bounds)}
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
            data-terminal-surface-mount="true"
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
          data-pane-command={Map.get(pane, :current_command)}
          data-pane-role={Map.get(pane, :role)}
          data-pane-paired={pane_paired_attr(pane)}
          data-scroll-policy={PaneInteraction.scroll_policy(pane)}
          data-scroll-backend={PaneInteraction.scroll_backend(pane)}
          data-mobile-pane-active={to_string(pane.id == @mobile_focus_pane_id)}
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
            if(pane.feature_pane?, do: "bg-zinc-950", else: "bg-transparent")
          ]}
          style={tmux_pane_style(pane, @tmux_pane_bounds)}
        >
          <%= if @tmux_mutations_enabled? and
                    not pane_ui_active?(pane, @ui_highlight_pane_id, @tmux_active_pane_id) do %>
            <.pane_resize_handles pane_id={pane.id} />
          <% end %>
          <%= if Map.get(pane, :paired) == false do %>
            <div
              class="pointer-events-none absolute right-1 top-1 z-30 rounded-sm border border-amber-500/40 bg-amber-500/15 px-1 font-mono text-[10px] leading-4 text-amber-300"
              title={pane_unpaired_title(pane)}
              data-role="pane-unpaired-badge"
            >
              unpaired
            </div>
          <% end %>
          <%= if pane.feature_pane? do %>
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
      <%!-- One generic feature-pane overlay loop: any tmux pane occupied by a
           feature pane gets its type-specific overlay component (preview
           iframe / file editor). Adding a pane type means adding a component
           clause here, not a new loop. --%>
      <%= for pane <- @active_tmux_window_panes,
               entry = feature_overlay_entry(@preview_panes, @file_panes, pane.id),
               not is_nil(entry) do %>
        <%= case entry do %>
          <% {:preview, preview} -> %>
            <.preview_pane_overlay
              pane={pane}
              preview={preview}
              bounds={@tmux_pane_bounds}
              active_tmux_session={@active_tmux_session}
              mobile_focus_pane_id={@mobile_focus_pane_id}
              entered_preview_pane_id={@entered_preview_pane_id}
              tmux_mutations_enabled?={@tmux_mutations_enabled?}
              ui_highlight_pane_id={@ui_highlight_pane_id}
              tmux_active_pane_id={@tmux_active_pane_id}
            />
          <% {:file, file_pane} -> %>
            <.file_pane_overlay
              pane={pane}
              file_pane={file_pane}
              bounds={@tmux_pane_bounds}
              mobile_focus_pane_id={@mobile_focus_pane_id}
              tmux_mutations_enabled?={@tmux_mutations_enabled?}
              ui_highlight_pane_id={@ui_highlight_pane_id}
              tmux_active_pane_id={@tmux_active_pane_id}
            />
        <% end %>
      <% end %>
      <%= for rail <- @mobile_pane_rails do %>
        <button
          type="button"
          phx-click="tmux:select_pane"
          phx-value-pane-id={rail.pane.id}
          data-mobile-pane-rail={rail.direction}
          data-mobile-pane-target={rail.pane.id}
          class="mobile-pane-rail group"
          style={mobile_pane_rail_style(rail)}
          title={"Focus pane #{rail.pane.index}: " <> pane_full_title(rail.pane)}
          aria-label={"Focus pane #{rail.pane.index}: " <> pane_full_title(rail.pane)}
        >
          <span class={["mobile-pane-rail__track", mobile_pane_rail_track_class(rail.direction)]}>
            <.icon name={mobile_pane_rail_icon(rail.direction)} class="size-3" />
          </span>
        </button>
      <% end %>
      <%= if @pane_history do %>
        <aside
          id="pane-history-drawer"
          phx-hook="PaneHistoryDrawer"
          data-history-key={@pane_history.key}
          data-history-ready={to_string(not is_nil(@pane_history.term))}
          data-history-refreshed-at={@pane_history.refreshed_at}
          class="absolute inset-y-0 right-0 z-40 flex w-full flex-col border-l border-zinc-800 bg-zinc-950/96 shadow-2xl shadow-black/50 backdrop-blur-sm sm:w-[min(46rem,56vw)]"
          phx-window-keydown="pane:history_close"
          phx-key="escape"
        >
          <div class="flex items-center gap-2 border-b border-zinc-800 bg-zinc-950 px-3 py-2">
            <div class="min-w-0 flex-1">
              <div class="truncate text-[10px] font-semibold uppercase text-zinc-500">
                Pane Scrollback
              </div>
              <div class="mt-0.5 truncate font-mono text-xs text-zinc-200">
                {@pane_history.title}
              </div>
            </div>
            <button
              type="button"
              phx-click="pane:history_open"
              phx-value-pane-id={@pane_history.pane_id}
              class="inline-flex size-8 shrink-0 items-center justify-center rounded border border-zinc-700 bg-zinc-900 text-zinc-200 transition hover:border-sky-400 hover:text-sky-100"
              title="Refresh scrollback"
              aria-label="Refresh scrollback"
            >
              <.icon name="hero-arrow-path" class="size-4" />
            </button>
            <button
              type="button"
              data-history-latest
              class="inline-flex size-8 shrink-0 items-center justify-center rounded border border-zinc-700 bg-zinc-900 text-zinc-200 transition hover:border-emerald-400 hover:text-emerald-100"
              title="Jump to latest"
              aria-label="Jump to latest"
            >
              <.icon name="hero-arrow-down" class="size-4" />
            </button>
            <button
              type="button"
              phx-click="pane:history_close"
              class="inline-flex size-8 shrink-0 items-center justify-center rounded border border-zinc-700 bg-zinc-900 text-zinc-200 transition hover:border-zinc-500 hover:text-white"
              title="Close scrollback drawer"
              aria-label="Close scrollback drawer"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
          <div
            data-history-scroll
            class="min-h-0 flex-1 overflow-auto bg-zinc-950 p-3"
          >
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
                Loading scrollback…
              </div>
            <% end %>
          </div>
          <div class="flex items-center justify-between gap-3 border-t border-zinc-800 bg-zinc-950 px-3 py-2 text-[10px] text-zinc-500">
            <div class="min-w-0 truncate font-mono">
              {@pane_history.session} · {@pane_history.window_id} · {@pane_history.pane_id}
            </div>
            <div data-history-pin-state class="shrink-0 font-medium text-zinc-400">
              Following latest
            </div>
          </div>
        </aside>
      <% end %>
    </div>
    """
  end

  @doc """
  Resolves which feature-pane overlay (if any) a tmux pane id hosts.

  `preview_panes` is the enriched preview map (derived from `:feature_panes`),
  `file_panes` the `:file` entries of `:feature_panes`. A tmux pane hosts at
  most one feature pane; previews win if both registries ever claim one id.
  """
  def feature_overlay_entry(preview_panes, file_panes, pane_id) do
    cond do
      preview = Map.get(preview_panes || %{}, pane_id) -> {:preview, preview}
      file_pane = Map.get(file_panes || %{}, pane_id) -> {:file, file_pane}
      true -> nil
    end
  end

  attr :pane, :map, required: true
  attr :preview, :map, required: true
  attr :bounds, :map, required: true
  attr :active_tmux_session, :any, default: nil
  attr :mobile_focus_pane_id, :any, default: nil
  attr :entered_preview_pane_id, :any, default: nil
  attr :tmux_mutations_enabled?, :boolean, required: true
  attr :ui_highlight_pane_id, :any, default: nil
  attr :tmux_active_pane_id, :any, default: nil

  defp preview_pane_overlay(assigns) do
    ~H"""
    <div
      id={"preview-pane-" <> dom_fragment(@pane.id)}
      phx-update="ignore"
      phx-hook="PreviewPaneOverlay"
      data-pane-id={@pane.id}
      data-ctx-menu="preview_pane"
      data-ctx-pane-id={@pane.id}
      data-ctx-url={@preview.display_url}
      data-pane-rect={pane_rect_json(@pane, @bounds)}
      data-display-url={@preview.display_url}
      data-playback-mode={preview_playback_mode?(@preview)}
      data-preview-tmux-session={preview_tmux_session(@preview)}
      data-active-tmux-session={@active_tmux_session}
      data-preview-session-mismatch={
        to_string(preview_session_mismatch?(@preview, @active_tmux_session))
      }
      data-mobile-pane-active={to_string(@pane.id == @mobile_focus_pane_id)}
      data-viewport={preview_viewport_label(@preview)}
      data-snapshot-mode={preview_snapshot_mode?(@preview)}
      class={[
        "preview-pane-overlay isolate overflow-hidden bg-zinc-950",
        @entered_preview_pane_id == @pane.id && "preview-pane-entered"
      ]}
    >
      <%= if @tmux_mutations_enabled? and
                not pane_ui_active?(@pane, @ui_highlight_pane_id, @tmux_active_pane_id) do %>
        <.pane_resize_handles pane_id={@pane.id} prefix="preview-pane" z_class="z-30" />
      <% end %>
      <div
        data-preview-shield
        class="pointer-events-none absolute inset-0 z-10 bg-transparent"
      >
      </div>
      <div data-preview-clip class="absolute inset-0 z-0 overflow-hidden bg-white">
        <iframe
          data-preview-iframe
          data-src={@preview.display_url}
          title={preview_pane_title(@preview)}
          loading="lazy"
          sandbox={preview_iframe_sandbox(@preview)}
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
          title={preview_session_title(@preview, @active_tmux_session)}
          class={[
            "max-w-full truncate rounded border px-2 py-1 text-[10px] font-medium leading-none shadow-sm backdrop-blur",
            if(preview_session_mismatch?(@preview, @active_tmux_session),
              do: "border-amber-300/50 bg-amber-950/85 text-amber-100",
              else: "border-zinc-700/70 bg-zinc-950/80 text-zinc-200"
            )
          ]}
        >
          {preview_session_label(@preview, @active_tmux_session)}
        </div>
      </div>
    </div>
    """
  end

  attr :pane, :map, required: true
  attr :file_pane, :map, required: true
  attr :bounds, :map, required: true
  attr :mobile_focus_pane_id, :any, default: nil
  attr :tmux_mutations_enabled?, :boolean, required: true
  attr :ui_highlight_pane_id, :any, default: nil
  attr :tmux_active_pane_id, :any, default: nil

  # File-pane overlay. The ROOT is diffed by LiveView (the tab strip is
  # server-rendered from the registry payload); only the inner editor div is
  # phx-update="ignore" so CodeMirror survives re-renders. The FilePaneOverlay
  # hook positions the root from data-pane-rect.
  defp file_pane_overlay(assigns) do
    ~H"""
    <div
      id={"file-pane-" <> dom_fragment(@pane.id)}
      phx-hook="FilePaneOverlay"
      data-pane-id={@pane.id}
      data-pane-rect={pane_rect_json(@pane, @bounds)}
      data-active-path={file_pane_active_path(@file_pane)}
      data-pane-active={
        to_string(pane_ui_active?(@pane, @ui_highlight_pane_id, @tmux_active_pane_id))
      }
      data-mobile-pane-active={to_string(@pane.id == @mobile_focus_pane_id)}
      class="file-pane-overlay isolate overflow-hidden border border-zinc-800/60 bg-zinc-950"
    >
      <%= if @tmux_mutations_enabled? and
                not pane_ui_active?(@pane, @ui_highlight_pane_id, @tmux_active_pane_id) do %>
        <.pane_resize_handles pane_id={@pane.id} prefix="file-pane" z_class="z-30" />
      <% end %>
      <div
        data-file-pane-tabs
        class="absolute inset-x-0 top-0 z-20 flex h-7 items-stretch overflow-x-auto border-b border-zinc-800 bg-zinc-900/95 text-[11px] text-zinc-300"
        role="tablist"
        aria-label="Open files"
      >
        <%= for tab <- file_pane_tabs(@file_pane) do %>
          <div
            data-file-pane-tab
            data-path={tab.path}
            data-ctx-menu="file_pane_tab"
            data-ctx-path={tab.path}
            data-ctx-target-id={"file-pane-" <> dom_fragment(@pane.id)}
            class={[
              "flex max-w-56 shrink-0 items-stretch border-r border-zinc-800",
              if(tab.path == file_pane_active_path(@file_pane),
                do: "bg-zinc-950 text-zinc-100",
                else: "hover:bg-zinc-800/70"
              )
            ]}
          >
            <button
              type="button"
              role="tab"
              aria-selected={to_string(tab.path == file_pane_active_path(@file_pane))}
              title={tab.path}
              phx-click={
                JS.push("pane:input",
                  value: %{"pane-id" => @pane.id, "type" => "activate_tab", "path" => tab.path}
                )
              }
              class="flex min-w-0 items-center gap-1 px-2 font-mono"
            >
              <span class="truncate">{tab.title}</span>
              <span
                data-dirty-dot
                class="hidden shrink-0 text-[9px] leading-none text-amber-400"
                aria-label="Unsaved changes"
              >
                ●
              </span>
            </button>
            <button
              type="button"
              phx-click={
                JS.dispatch("devide:file-pane:close-tab",
                  to: "[id='file-pane-" <> dom_fragment(@pane.id) <> "']",
                  detail: %{path: tab.path}
                )
              }
              title={"Close " <> tab.title}
              aria-label={"Close " <> tab.title}
              class="shrink-0 px-1 text-zinc-500 transition hover:text-zinc-100"
            >
              ×
            </button>
          </div>
        <% end %>
      </div>
      <div
        id={"file-pane-editor-" <> dom_fragment(@pane.id)}
        data-file-pane-editor
        data-ctx-menu="file_pane_editor"
        phx-update="ignore"
        class="file-pane-editor absolute inset-x-0 bottom-0 top-7 z-10 overflow-hidden bg-zinc-950"
      >
      </div>
    </div>
    """
  end

  @doc """
  A tmux pane's rectangle as percentages of the window bounds, JSON-encoded for
  the overlay hooks' `data-pane-rect` (shared by preview and file overlays).
  """
  def pane_rect_json(pane, bounds) do
    %{
      left: percentage(tmux_dimension(pane.left), bounds.width),
      top: percentage(tmux_dimension(pane.top), bounds.height),
      width: percentage(tmux_dimension(pane.width), bounds.width),
      height: percentage(tmux_dimension(pane.height), bounds.height)
    }
    |> Jason.encode!()
  end

  # Back-compat name (tests + external callers predate the file-pane overlay).
  def preview_pane_rect_json(pane, bounds), do: pane_rect_json(pane, bounds)

  @doc "Tabs of a `:file` feature-pane entry, normalized to `%{path, title, line}`."
  def file_pane_tabs(%{payload: payload}) when is_map(payload) do
    (feature_value(payload, :tabs) || [])
    |> Enum.flat_map(fn tab ->
      case feature_value(tab, :path) do
        path when is_binary(path) and path != "" ->
          [
            %{
              path: path,
              title: feature_value(tab, :title) || Path.basename(path),
              line: feature_value(tab, :line)
            }
          ]

        _ ->
          []
      end
    end)
  end

  def file_pane_tabs(_entry), do: []

  @doc "Active tab path of a `:file` feature-pane entry, or nil."
  def file_pane_active_path(%{payload: payload}) when is_map(payload),
    do: feature_value(payload, :active_path)

  def file_pane_active_path(_entry), do: nil

  defp feature_value(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp feature_value(_map, _key), do: nil

  defp mobile_pane_rail_icon(:left), do: "hero-chevron-left"
  defp mobile_pane_rail_icon(:right), do: "hero-chevron-right"
  defp mobile_pane_rail_icon(:top), do: "hero-chevron-up"
  defp mobile_pane_rail_icon(:bottom), do: "hero-chevron-down"

  defp mobile_pane_rail_track_class(:left),
    do: "left-0 inset-y-1 w-[0.6rem] border-r border-sky-200/30"

  defp mobile_pane_rail_track_class(:right),
    do: "right-0 inset-y-1 w-[0.6rem] border-l border-sky-200/30"

  defp mobile_pane_rail_track_class(:top),
    do: "top-0 inset-x-1 h-[0.6rem] border-b border-sky-200/30"

  defp mobile_pane_rail_track_class(:bottom),
    do: "bottom-0 inset-x-1 h-[0.6rem] border-t border-sky-200/30"

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

  @doc "The session's git branch, or `nil` when it has no git context."
  def session_branch(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :git_branch) || Map.get(metadata, "git_branch")
  end

  def session_branch(_), do: nil

  @doc "True when the session's cwd lives in a linked git worktree."
  def session_worktree?(%{metadata: metadata}) when is_map(metadata) do
    (Map.get(metadata, :git_worktree?) || Map.get(metadata, "git_worktree?")) == true
  end

  def session_worktree?(_), do: false

  @doc """
  The anchor repository name for a session. For a linked worktree this is the
  *main* repo (derived from `git_common_dir`, which points at the primary
  checkout's `.git`) — the "where you came from" a worktree cwd otherwise
  hides. For a normal checkout it is the toplevel basename.
  """
  def session_repo_label(info) when is_map(info) do
    worktree_repo_label(info) || toplevel_repo_label(info)
  end

  def session_repo_label(_), do: nil

  defp worktree_repo_label(info) do
    common_dir = session_git_common_dir(info)

    if session_worktree?(info) and is_binary(common_dir) and common_dir != "" do
      # `.../mainrepo/.git` → dirname `.../mainrepo` → basename `mainrepo`.
      common_dir |> Path.dirname() |> Path.basename() |> blank_repo_to_nil()
    end
  end

  defp toplevel_repo_label(info) do
    case session_git_toplevel(info) do
      toplevel when is_binary(toplevel) and toplevel != "" -> Path.basename(toplevel)
      _ -> nil
    end
  end

  defp session_git_common_dir(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, :git_common_dir) || Map.get(metadata, "git_common_dir")
  end

  defp session_git_common_dir(_), do: nil

  # A degenerate common-dir (root, ".", or a bare ".git") yields no useful repo
  # anchor — fall through to the toplevel basename instead of showing junk.
  defp blank_repo_to_nil(name) when name in ["", ".", "/", ".git"], do: nil
  defp blank_repo_to_nil(name), do: name

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
