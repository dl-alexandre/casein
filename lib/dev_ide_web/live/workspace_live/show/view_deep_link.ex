defmodule DevIdeWeb.WorkspaceLive.Show.ViewDeepLink do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  use DevIdeWeb, :verified_routes

  alias DevIdeWeb.WorkspaceLive.Show.TerminalState

  @query_param_order ~w(host session window pane zoom)
  @idle_patch_threshold_ms 4_000

  def idle_patch_threshold_ms, do: @idle_patch_threshold_ms

  def stash_url_view(socket, params) when is_map(params) do
    socket
    |> assign(:pending_url_pane, normalize_param(params["pane"]))
    |> assign(:pending_url_zoom, zoom_param?(params["zoom"]))
    |> assign(:pending_url_recovery, recovery_params(params))
  end

  def apply_pending_url_recovery(socket) do
    pending = socket.assigns[:pending_url_recovery]

    if topology_ready?(socket) and is_map(pending) and map_size(pending) > 0 do
      maybe_patch_recovered_view_url_connected(
        assign(socket, :pending_url_recovery, nil),
        pending
      )
    else
      socket
    end
  end

  def apply_pending_url_view(socket) do
    pending_pane = socket.assigns[:pending_url_pane]
    pending_zoom = socket.assigns[:pending_url_zoom]

    if topology_ready?(socket) and (pending_pane || pending_zoom) do
      socket =
        socket
        |> assign(:pending_url_pane, nil)
        |> assign(:pending_url_zoom, nil)

      socket
      |> apply_pending_pane(pending_pane)
      |> apply_pending_zoom(pending_zoom, pending_pane)
    else
      socket
    end
  end

  def workspace_view_path(socket, window_id \\ nil) do
    window_id = window_id || socket.assigns[:tmux_active_window_id]
    workspace_id = socket.assigns.workspace.id

    query =
      query_map(socket, window_id)
      |> encode_query()

    base = path_base(socket, workspace_id)
    if query == "", do: base, else: base <> "?" <> query
  end

  def patch_current_view(socket, opts \\ []) do
    path = workspace_view_path(socket)
    socket = assign(socket, :patched_view_path, path)
    force? = Keyword.get(opts, :force, false)

    if force? or is_nil(socket.redirected) do
      push_patch(socket, to: path)
    else
      socket
    end
  end

  @doc """
  Patch the address bar when tmux topology drifted the view, but only if the
  operator has been idle long enough (avoids fighting rapid CLI usage).
  """
  def maybe_patch_idle_view_url(socket) do
    if connected?(socket), do: maybe_patch_idle_view_url_connected(socket), else: socket
  end

  @doc false
  def maybe_patch_idle_view_url_connected(socket) do
    if topology_ready?(socket) do
      path = workspace_view_path(socket)
      prev = socket.assigns[:patched_view_path]

      cond do
        prev == path ->
          socket

        is_nil(prev) ->
          assign(socket, :patched_view_path, path)

        terminal_idle?(socket) ->
          patch_current_view(socket)

        true ->
          socket
      end
    else
      socket
    end
  end

  def seed_patched_view_path(socket) do
    if topology_ready?(socket) do
      assign(socket, :patched_view_path, workspace_view_path(socket))
    else
      socket
    end
  end

  @doc """
  Patch the address bar when a shared deep link pointed at a session/window that
  no longer exists and we silently landed on the closest live view instead.

  Unlike idle-gated topology patches, this runs immediately on navigation so a
  post-deploy bookmark does not keep a dead `?session=` / `?window=` in the bar.
  """
  def maybe_patch_recovered_view_url(socket, params) when is_map(params) do
    if connected?(socket),
      do: maybe_patch_recovered_view_url_connected(socket, params),
      else: socket
  end

  @doc false
  def maybe_patch_recovered_view_url_connected(socket, params) when is_map(params) do
    if topology_ready?(socket) and view_url_stale?(socket, params) do
      path = workspace_view_path(socket)

      socket
      |> assign(:patched_view_path, path)
      |> schedule_recovered_view_patch()
    else
      socket
    end
  end

  @doc false
  def schedule_recovered_view_patch(socket) do
    case socket.assigns[:patched_view_path] do
      path when is_binary(path) and path != "" ->
        send(self(), {:patch_recovered_view_url, path})
        socket

      _ ->
        socket
    end
  end

  @doc false
  def push_recovered_view_path(socket, path) when is_binary(path) do
    socket = assign(socket, :patched_view_path, path)

    if is_nil(socket.redirected) do
      push_patch(socket, to: path)
    else
      socket
    end
  end

  def touch_terminal_interaction(socket) do
    assign(socket, :terminal_last_interaction_ms, System.monotonic_time(:millisecond))
  end

  def terminal_idle?(socket, threshold_ms \\ @idle_patch_threshold_ms) do
    case socket.assigns[:terminal_last_interaction_ms] do
      nil -> true
      last when is_integer(last) -> System.monotonic_time(:millisecond) - last >= threshold_ms
      _ -> true
    end
  end

  def share_query_opts(socket_or_assigns) do
    socket = normalize_assigns_socket(socket_or_assigns)
    window_id = socket.assigns[:tmux_active_window_id]

    [
      pane: pane_query_param(socket, window_id),
      zoom: window_zoomed?(socket, window_id),
      # Share links use the canonical workspace route (no inner segments) so
      # a copied link always lands on the workspace root.
      path_base: socket.assigns[:workspace_route]
    ]
  end

  defp normalize_assigns_socket(%{assigns: _} = socket), do: socket
  defp normalize_assigns_socket(assigns) when is_map(assigns), do: %{assigns: assigns}

  def build_share_path(workspace_id, session_id, window_id, opts \\ []) do
    pane = Keyword.get(opts, :pane)
    zoom? = Keyword.get(opts, :zoom) == true

    query =
      %{
        "session" => session_id,
        "window" => window_id,
        "pane" => if(zoom? or is_binary(pane), do: pane, else: nil),
        "zoom" => if(zoom?, do: "1")
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> encode_query()

    base =
      case Keyword.get(opts, :path_base) do
        path_base when is_binary(path_base) and path_base != "" -> path_base
        _ -> ~p"/workspaces/#{workspace_id}"
      end

    base <> if(query == "", do: "", else: "?" <> query)
  end

  defp apply_pending_pane(socket, pane_id) when is_binary(pane_id) and pane_id != "" do
    apply_requested_pane(socket, pane_id)
  end

  defp apply_pending_pane(socket, _pane_id), do: socket

  # When the requested pane (or its window) is gone, silently stay on the closest
  # live view rather than surfacing a "no longer available" banner.
  defp apply_requested_pane(socket, pane_id) do
    panes = socket.assigns[:tmux_panes] || []

    case Enum.find(panes, &(Map.get(&1, :id) == pane_id)) do
      nil ->
        socket

      %{window_id: window_id} ->
        {socket, window_ok?} =
          if window_id != socket.assigns[:tmux_active_window_id] do
            case TerminalState.tmux_adapter().select_window(
                   socket.assigns.tmux_session,
                   window_id
                 ) do
              :ok -> {TerminalState.refresh_tmux_topology(socket), true}
              {:error, _} -> {socket, false}
            end
          else
            {socket, true}
          end

        if window_ok? and pane_id != socket.assigns[:tmux_active_pane_id] do
          case TerminalState.tmux_adapter().select_pane(socket.assigns.tmux_session, pane_id) do
            :ok -> TerminalState.refresh_tmux_topology(socket)
            {:error, _} -> socket
          end
        else
          socket
        end
    end
  end

  # Zoom is best-effort restore from a shared link; if it can't be applied we keep
  # the live (unzoomed) view rather than nagging with a banner.
  defp apply_pending_zoom(socket, pending_zoom, pending_pane) do
    cond do
      pending_zoom != true ->
        socket

      not is_binary(pending_pane) ->
        socket

      true ->
        case TerminalState.tmux_adapter().ensure_zoomed(
               socket.assigns.tmux_session,
               pending_pane,
               true
             ) do
          :ok ->
            TerminalState.refresh_tmux_topology(socket)

          {:error, _reason} ->
            socket
        end
    end
  end

  defp query_map(socket, window_id) do
    %{
      "host" => host_query_param(socket.assigns[:host_id]),
      "session" => selected_session_param(socket),
      "window" => window_id,
      "pane" => pane_query_param(socket, window_id),
      "zoom" => zoom_query_param(socket, window_id)
    }
  end

  # Address-bar patching keeps the full requested route (inner segments
  # included) so the URL stays what the operator typed.
  defp path_base(socket, workspace_id) do
    case socket.assigns[:path_route] do
      path when is_binary(path) and path != "" -> path
      _ -> ~p"/workspaces/#{workspace_id}"
    end
  end

  defp pane_query_param(socket, window_id) do
    panes = socket.assigns[:tmux_panes] || []
    pane_id = pane_id_for_window(socket, window_id, panes)

    cond do
      not is_binary(pane_id) ->
        nil

      window_pane_count(panes, window_id) <= 1 and window_zoomed?(socket, window_id) != true ->
        nil

      true ->
        pane_id
    end
  end

  defp pane_id_for_window(socket, window_id, panes) do
    active_id = socket.assigns[:tmux_active_pane_id]

    if Enum.any?(panes, fn pane ->
         Map.get(pane, :id) == active_id and Map.get(pane, :window_id) == window_id
       end) do
      active_id
    else
      Enum.find_value(panes, fn pane ->
        if Map.get(pane, :window_id) == window_id and Map.get(pane, :active),
          do: Map.get(pane, :id)
      end) ||
        Enum.find_value(panes, fn pane ->
          if Map.get(pane, :window_id) == window_id, do: Map.get(pane, :id)
        end)
    end
  end

  defp zoom_query_param(socket, window_id) do
    if window_zoomed?(socket, window_id), do: "1"
  end

  defp window_zoomed?(socket, window_id) do
    socket.assigns[:window_zoomed?] == true and
      socket.assigns[:tmux_active_window_id] == window_id
  end

  defp selected_session_param(socket) do
    sid = socket.assigns[:terminal_sid]
    if is_binary(sid) and sid != "", do: sid
  end

  defp host_query_param(host_id) when host_id in [nil, "", "local"], do: nil
  defp host_query_param(host_id), do: host_id

  defp window_pane_count(panes, window_id) do
    Enum.count(panes, &(Map.get(&1, :window_id) == window_id))
  end

  defp encode_query(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Enum.sort_by(fn {key, _} -> Enum.find_index(@query_param_order, &(&1 == key)) || 99 end)
    |> URI.encode_query()
  end

  defp recovery_params(params) when is_map(params) do
    %{
      "session" => normalize_param(params["session"]),
      "window" => normalize_param(params["window"]),
      "pane" => normalize_param(params["pane"]),
      "zoom" => if(zoom_param?(params["zoom"]), do: "1", else: nil)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp view_url_stale?(socket, params) do
    current_params =
      workspace_view_path(socket) |> URI.parse() |> Map.get(:query, "") |> decode_query()

    Enum.any?(["session", "window", "pane", "zoom"], fn key ->
      requested = normalize_param(params[key])
      is_binary(requested) and requested != Map.get(current_params, key)
    end)
  end

  defp decode_query(""), do: %{}

  defp decode_query(query) when is_binary(query) do
    URI.decode_query(query)
  end

  defp topology_ready?(socket) do
    socket.assigns[:tmux_topology_version] not in [nil, 0] and
      is_binary(socket.assigns[:tmux_active_window_id]) and
      socket.assigns[:tmux_active_window_id] != ""
  end

  defp normalize_param(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_param(_), do: nil

  defp zoom_param?(value) when value in ["1", "true", "yes", "on"], do: true
  defp zoom_param?(_), do: false
end
