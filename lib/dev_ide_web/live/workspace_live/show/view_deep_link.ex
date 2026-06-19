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

    base = ~p"/workspaces/#{workspace_id}"
    if query == "", do: base, else: base <> "?" <> query
  end

  def patch_current_view(socket) do
    path = workspace_view_path(socket)
    socket = assign(socket, :patched_view_path, path)

    if is_nil(socket.redirected) do
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
      zoom: window_zoomed?(socket, window_id)
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

    ~p"/workspaces/#{workspace_id}" <> if(query == "", do: "", else: "?" <> query)
  end

  def assign_window_notice(socket, window_id) do
    assign_view_link_notice(socket, :window, window_id)
  end

  def assign_view_link_notice(socket, kind, requested) do
    assign(socket, :view_link_notice, %{
      kind: kind,
      requested: requested,
      alternatives: view_link_alternatives(socket, kind)
    })
  end

  def clear_view_link_notice(socket), do: assign(socket, :view_link_notice, nil)

  defp apply_pending_pane(socket, pane_id) when is_binary(pane_id) and pane_id != "" do
    apply_requested_pane(socket, pane_id)
  end

  defp apply_pending_pane(socket, _pane_id), do: socket

  defp apply_requested_pane(socket, pane_id) do
    panes = socket.assigns[:tmux_panes] || []

    case Enum.find(panes, &(Map.get(&1, :id) == pane_id)) do
      nil ->
        assign_view_link_notice(socket, :pane, pane_id)

      %{window_id: window_id} ->
        socket =
          if window_id != socket.assigns[:tmux_active_window_id] do
            case TerminalState.tmux_adapter().select_window(
                   socket.assigns.tmux_session,
                   window_id
                 ) do
              :ok -> TerminalState.refresh_tmux_topology(socket)
              {:error, _} -> assign_view_link_notice(socket, :pane, pane_id)
            end
          else
            socket
          end

        if socket.assigns[:view_link_notice] == nil and
             pane_id != socket.assigns[:tmux_active_pane_id] do
          case TerminalState.tmux_adapter().select_pane(socket.assigns.tmux_session, pane_id) do
            :ok -> TerminalState.refresh_tmux_topology(socket)
            {:error, _} -> assign_view_link_notice(socket, :pane, pane_id)
          end
        else
          socket
        end
    end
  end

  defp apply_pending_zoom(socket, pending_zoom, pending_pane) do
    cond do
      pending_zoom != true ->
        socket

      not is_binary(pending_pane) ->
        assign_view_link_notice(socket, :zoom, "1")

      true ->
        case TerminalState.tmux_adapter().ensure_zoomed(
               socket.assigns.tmux_session,
               pending_pane,
               true
             ) do
          :ok ->
            TerminalState.refresh_tmux_topology(socket)

          {:error, _reason} ->
            assign_view_link_notice(socket, :zoom, pending_pane)
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

  defp view_link_alternatives(socket, :session) do
    ws = socket.assigns.workspace
    ws_id = ws.id
    default_sid = socket.assigns[:default_terminal_sid]

    shell =
      if is_binary(default_sid) and default_sid != "" do
        [
          %{
            label: socket.assigns[:shell_button_label] || "Shell",
            patch: session_patch(ws_id, default_sid)
          }
        ]
      else
        []
      end

    tabs =
      ws
      |> TerminalState.terminal_session_tabs(default_sid)
      |> DevIdeWeb.WorkspaceLive.Show.SessionBarVM.session_tabs()
      |> Enum.map(fn tab ->
        %{label: tab.label, patch: session_patch(ws_id, tab.id)}
      end)

    shell ++ tabs
  end

  defp view_link_alternatives(socket, _kind) do
    ws_id = socket.assigns.workspace.id
    sid = socket.assigns[:terminal_sid]

    if is_binary(sid) and sid != "" do
      [%{label: "Current session", patch: session_patch(ws_id, sid)}]
    else
      []
    end
  end

  defp session_patch(workspace_id, session_id) do
    ~p"/workspaces/#{workspace_id}?session=#{session_id}"
  end
end
