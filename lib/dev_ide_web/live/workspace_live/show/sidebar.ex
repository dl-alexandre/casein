defmodule DevIdeWeb.WorkspaceLive.Show.Sidebar do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_event: 3, start_async: 3]

  alias DevIDE.Terminals
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Workspaces.SessionSummary
  alias DevIdeWeb.WorkspaceLive.Show.SessionBarVM

  @type sidebar_mode :: :closed | :windows_only | :both

  @spec initial_assigns() :: keyword()
  def initial_assigns do
    [
      sidebar_mode: :closed,
      window_sidebar_open?: false,
      sessions_sidebar_open?: false,
      sidebar_expanded_workspaces: MapSet.new(),
      sidebar_expanded_windows: MapSet.new(),
      sidebar_ws_sessions: %{},
      sidebar_ws_subscriptions: MapSet.new(),
      sessions_sidebar_tree: [],
      windows_sidebar_tree: [],
      sessions_sidebar_sort: :recency,
      windows_sidebar_sort: :recency
    ]
  end

  @spec open(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def open(socket, mode) when mode in ["windows", "both"] do
    sidebar_mode =
      case mode do
        "both" -> :both
        _ -> :windows_only
      end

    current_id = socket.assigns.workspace.id

    expanded =
      socket.assigns.sidebar_expanded_workspaces
      |> then(fn set ->
        if sidebar_mode == :both, do: MapSet.put(set, current_id), else: set
      end)

    expanded_windows = expanded_windows_on_open(socket)

    socket =
      socket
      |> assign_sidebar_mode(sidebar_mode)
      |> assign(:sidebar_expanded_workspaces, expanded)
      |> assign(:sidebar_expanded_windows, expanded_windows)
      |> assign_sessions_sidebar_tree()
      |> assign_windows_sidebar_tree()

    if sidebar_mode == :both do
      push_event(socket, "sidebar:focus_sessions", %{})
    else
      socket
    end
  end

  @spec close(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def close(socket) do
    socket
    |> unsubscribe_all_sidebar_workspaces()
    |> assign_sidebar_mode(:closed)
    |> assign(:sidebar_expanded_workspaces, MapSet.new())
    |> assign(:sidebar_expanded_windows, MapSet.new())
    |> assign(:sidebar_ws_sessions, %{})
    |> assign(:sidebar_ws_subscriptions, MapSet.new())
    |> assign(:sessions_sidebar_tree, [])
    |> assign(:windows_sidebar_tree, [])
    |> assign(:sessions_sidebar_sort, :recency)
    |> assign(:windows_sidebar_sort, :recency)
  end

  @spec reveal_sessions(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reveal_sessions(socket) do
    current_id = socket.assigns.workspace.id

    socket =
      socket
      |> assign_sidebar_mode(:both)
      |> assign(
        :sidebar_expanded_workspaces,
        MapSet.put(socket.assigns.sidebar_expanded_workspaces, current_id)
      )
      |> assign_sessions_sidebar_tree()
      |> push_event("sidebar:focus_sessions", %{})

    socket
  end

  @spec toggle_window(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_window(socket, window_id) when is_binary(window_id) do
    expanded = socket.assigns.sidebar_expanded_windows

    expanded =
      if MapSet.member?(expanded, window_id) do
        MapSet.delete(expanded, window_id)
      else
        MapSet.put(expanded, window_id)
      end

    socket
    |> assign(:sidebar_expanded_windows, expanded)
    |> assign_windows_sidebar_tree()
  end

  @spec assign_windows_sidebar_tree(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_windows_sidebar_tree(socket) do
    tree =
      if socket.assigns.window_sidebar_open? do
        socket.assigns.tmux_window_tabs
        |> SessionBarVM.window_tree(expanded_windows: socket.assigns.sidebar_expanded_windows)
        |> SessionBarVM.sort_window_tree(socket.assigns.windows_sidebar_sort)
      else
        []
      end

    assign(socket, :windows_sidebar_tree, tree)
  end

  @spec cycle_sessions_sort(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cycle_sessions_sort(socket) do
    mode = SessionBarVM.cycle_sort_mode(socket.assigns.sessions_sidebar_sort)

    socket
    |> assign(:sessions_sidebar_sort, mode)
    |> assign_sessions_sidebar_tree()
  end

  @spec cycle_windows_sort(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def cycle_windows_sort(socket) do
    mode = SessionBarVM.cycle_sort_mode(socket.assigns.windows_sidebar_sort)

    socket
    |> assign(:windows_sidebar_sort, mode)
    |> assign_windows_sidebar_tree()
  end

  @spec toggle_workspace(Phoenix.LiveView.Socket.t(), String.t()) :: Phoenix.LiveView.Socket.t()
  def toggle_workspace(socket, workspace_id) when is_binary(workspace_id) do
    expanded = socket.assigns.sidebar_expanded_workspaces

    if MapSet.member?(expanded, workspace_id) do
      collapse_workspace(socket, workspace_id)
    else
      expand_workspace(socket, workspace_id)
    end
  end

  @spec assign_sessions_sidebar_tree(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_sessions_sidebar_tree(socket) do
    socket = ensure_current_workspace_summary(socket)

    summaries =
      SessionBarVM.sort_workspace_summaries_for_sidebar(
        socket.assigns.workspace_summaries,
        socket.assigns.sessions_sidebar_sort,
        socket.assigns.workspace.id
      )

    tree =
      summaries
      |> SessionBarVM.workspace_session_tree(
        socket.assigns.workspace.id,
        expanded_workspaces: socket.assigns.sidebar_expanded_workspaces,
        current_session_tabs: socket.assigns.session_tabs,
        sidebar_ws_sessions: socket.assigns.sidebar_ws_sessions
      )
      |> SessionBarVM.sort_sessions_in_tree(socket.assigns.sessions_sidebar_sort)

    assign(socket, :sessions_sidebar_tree, tree)
  end

  @spec assign_sidebar_ws_sessions(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          [map()]
        ) :: Phoenix.LiveView.Socket.t()
  def assign_sidebar_ws_sessions(socket, workspace_id, infos) when is_list(infos) do
    summary = find_summary(socket, workspace_id)
    workspace_name = summary_workspace_name(summary, workspace_id)
    default_sid = SessionSummary.newest_shell_sid(workspace_id, workspace_name)

    tabs =
      infos
      |> Terminals.visible_tabs(default_sid)
      |> SessionBarVM.session_tabs()

    assign(socket, :sidebar_ws_sessions, Map.put(socket.assigns.sidebar_ws_sessions, workspace_id, tabs))
  end

  @spec handle_async_sessions(
          Phoenix.LiveView.Socket.t(),
          String.t(),
          {:ok, [map()]} | {:error, term()}
        ) :: Phoenix.LiveView.Socket.t()
  def handle_async_sessions(socket, workspace_id, {:ok, infos}) when is_list(infos) do
    socket
    |> assign_sidebar_ws_sessions(workspace_id, infos)
    |> assign_sessions_sidebar_tree()
  end

  def handle_async_sessions(socket, _workspace_id, _error) do
    assign_sessions_sidebar_tree(socket)
  end

  @spec sessions_updated(Phoenix.LiveView.Socket.t(), String.t(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def sessions_updated(socket, workspace_id, tabs) when is_list(tabs) do
    if MapSet.member?(socket.assigns.sidebar_ws_subscriptions, workspace_id) do
      socket
      |> assign_sidebar_ws_sessions(workspace_id, tabs)
      |> assign_sessions_sidebar_tree()
    else
      socket
    end
  end

  @spec maybe_focus_windows_after_attach(Phoenix.LiveView.Socket.t(), boolean()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_focus_windows_after_attach(socket, _attach?) do
    if socket.assigns.window_sidebar_open? do
      push_event(socket, "sidebar:focus_windows", %{})
    else
      socket
    end
  end

  defp assign_sidebar_mode(socket, mode) when mode in [:closed, :windows_only, :both] do
    socket
    |> assign(:sidebar_mode, mode)
    |> assign(:window_sidebar_open?, mode in [:windows_only, :both])
    |> assign(:sessions_sidebar_open?, mode == :both)
  end

  defp expand_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    socket =
      socket
      |> assign(
        :sidebar_expanded_workspaces,
        MapSet.put(socket.assigns.sidebar_expanded_workspaces, workspace_id)
      )
      |> assign_sessions_sidebar_tree()

    if workspace_id == current_id do
      socket
    else
      summary = find_summary(socket, workspace_id)
      workspace_name = summary_workspace_name(summary, workspace_id)

      socket
      |> subscribe_sidebar_workspace(workspace_id)
      |> start_async({:sidebar_ws_sessions, workspace_id}, fn ->
        SessionDirectory.read(workspace_id, workspace_name: workspace_name)
      end)
    end
  end

  defp collapse_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    socket =
      socket
      |> assign(
        :sidebar_expanded_workspaces,
        MapSet.delete(socket.assigns.sidebar_expanded_workspaces, workspace_id)
      )
      |> then(fn sock ->
        if workspace_id == current_id do
          sock
        else
          sock
          |> unsubscribe_sidebar_workspace(workspace_id)
          |> assign(:sidebar_ws_sessions, Map.delete(sock.assigns.sidebar_ws_sessions, workspace_id))
        end
      end)
      |> assign_sessions_sidebar_tree()

    socket
  end

  defp subscribe_sidebar_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    if workspace_id == current_id or MapSet.member?(socket.assigns.sidebar_ws_subscriptions, workspace_id) do
      socket
    else
      summary = find_summary(socket, workspace_id)
      workspace_name = summary_workspace_name(summary, workspace_id)

      if connected?(socket) do
        _ =
          Terminals.subscribe_session_tabs(workspace_id,
            workspace_name: workspace_name
          )
      end

      assign(
        socket,
        :sidebar_ws_subscriptions,
        MapSet.put(socket.assigns.sidebar_ws_subscriptions, workspace_id)
      )
    end
  end

  defp unsubscribe_sidebar_workspace(socket, workspace_id) do
    current_id = socket.assigns.workspace.id

    if workspace_id == current_id or
         not MapSet.member?(socket.assigns.sidebar_ws_subscriptions, workspace_id) do
      socket
    else
      if connected?(socket) do
        :ok = Terminals.unsubscribe_session_tabs(workspace_id)
      end

      assign(
        socket,
        :sidebar_ws_subscriptions,
        MapSet.delete(socket.assigns.sidebar_ws_subscriptions, workspace_id)
      )
    end
  end

  defp unsubscribe_all_sidebar_workspaces(socket) do
    Enum.reduce(socket.assigns.sidebar_ws_subscriptions, socket, fn workspace_id, sock ->
      unsubscribe_sidebar_workspace(sock, workspace_id)
    end)
  end

  defp ensure_current_workspace_summary(socket) do
    ws = socket.assigns.workspace
    current_id = ws.id

    if Enum.any?(socket.assigns.workspace_summaries, &(summary_id(&1) == current_id)) do
      socket
    else
      assign(socket, :workspace_summaries, [
        %{
          id: current_id,
          name: ws.name || current_id,
          session_count: length(socket.assigns.session_tabs),
          live?: true,
          sessions: []
        }
      ])
    end
  end

  defp find_summary(socket, workspace_id) do
    Enum.find(socket.assigns.workspace_summaries, &(summary_id(&1) == workspace_id))
  end

  defp summary_id(summary),
    do: Map.get(summary, :id) || Map.get(summary, "id")

  defp summary_workspace_name(summary, workspace_id) do
    name = Map.get(summary, :name) || Map.get(summary, "name")
    if is_binary(name) and name != "", do: name, else: workspace_id
  end

  defp expanded_windows_on_open(socket) do
    case Enum.find(socket.assigns.tmux_window_tabs || [], & &1.active?) do
      %{id: window_id, pane_count: count} when count > 1 ->
        MapSet.put(socket.assigns.sidebar_expanded_windows, window_id)

      _ ->
        socket.assigns.sidebar_expanded_windows
    end
  end

end
