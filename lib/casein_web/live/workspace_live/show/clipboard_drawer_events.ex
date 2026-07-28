defmodule CaseinWeb.WorkspaceLive.Show.ClipboardDrawerEvents do
  # Clipboard drawer state + handle_event clauses, delegated from
  # WorkspaceLive.Show (mirrors NotificationsDrawerEvents).
  #
  # Lazy by construction: mount subscribes to the workspace clipboard topic and
  # loads only the *count* for the badge; the copied text is pulled into socket
  # assigns the first time the drawer opens. That split matters here more than
  # elsewhere — retained payloads run to tens of kilobytes each, and holding
  # twenty of them in every viewer's assigns would inflate every diff.
  #
  # Workspace scoping: reads are keyed by the mounted
  # `socket.assigns.workspace.id`, never a client-supplied id.
  @moduledoc false

  import Phoenix.Component
  import Phoenix.LiveView, only: [connected?: 1]

  alias Casein.Terminals.ClipboardHistory

  # --- state -----------------------------------------------------------------

  @doc """
  Drawer defaults + workspace-topic subscription, piped from the LiveView mount.
  """
  def mount(socket) do
    workspace_id = workspace_id(socket)

    if connected?(socket) and is_binary(workspace_id) do
      ClipboardHistory.subscribe(workspace_id)
    end

    socket
    |> assign(:clipboard_drawer_open, false)
    |> assign(:clipboard_loaded?, false)
    |> assign(:clipboard_entries, [])
    |> assign(:clipboard_count, count(socket, workspace_id))
  end

  @doc "Open the drawer and run the first (connected-only) load of the copies."
  def open(socket) do
    socket = assign(socket, :clipboard_drawer_open, true)
    if connected?(socket), do: load_state(socket), else: socket
  end

  @doc """
  Record an OSC 52 payload a terminal program just asked to copy.

  Called from the LiveView's PTY side channel. Every attached viewer extracts
  the same sequence independently, so the store collapses duplicates; this only
  has to hand over what it saw.
  """
  def record(socket, pane_id, text) do
    workspace_id = workspace_id(socket)

    if is_binary(workspace_id) do
      ClipboardHistory.record(%{
        workspace_id: workspace_id,
        pane_id: pane_id,
        pane_label: pane_label(socket, pane_id),
        text: text
      })
    end

    socket
  end

  @doc """
  Live refresh from a `{:clipboard_history, entry}` broadcast: the badge always
  updates; the list refreshes only while the drawer is open.
  """
  def handle_history_change(socket) do
    if socket.assigns[:clipboard_drawer_open] and socket.assigns[:clipboard_loaded?] do
      load_state(socket)
    else
      assign(socket, :clipboard_count, count(socket, workspace_id(socket)))
    end
  end

  # --- handle_event ----------------------------------------------------------

  def handle_event("clipboard:toggle", _params, socket) do
    socket =
      if socket.assigns[:clipboard_drawer_open],
        do: assign(socket, :clipboard_drawer_open, false),
        else: open(socket)

    {:noreply, socket}
  end

  def handle_event("clipboard:close", _params, socket) do
    {:noreply, assign(socket, :clipboard_drawer_open, false)}
  end

  def handle_event("clipboard:refresh", _params, socket) do
    {:noreply, load_state(socket)}
  end

  def handle_event("clipboard:clear", _params, socket) do
    workspace_id = workspace_id(socket)
    if is_binary(workspace_id), do: ClipboardHistory.forget(workspace_id)

    {:noreply,
     socket
     |> assign(:clipboard_entries, [])
     |> assign(:clipboard_count, 0)}
  end

  # --- internals -------------------------------------------------------------

  defp load_state(socket) do
    workspace_id = workspace_id(socket)
    entries = if is_binary(workspace_id), do: ClipboardHistory.recent(workspace_id), else: []

    socket
    |> assign(:clipboard_entries, entries)
    |> assign(:clipboard_count, length(entries))
    |> assign(:clipboard_loaded?, true)
  end

  defp count(socket, workspace_id) do
    if connected?(socket) and is_binary(workspace_id) do
      ClipboardHistory.count(workspace_id)
    else
      0
    end
  end

  defp workspace_id(socket) do
    case socket.assigns[:workspace] do
      %{id: id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp pane_label(socket, pane_id) when is_binary(pane_id) do
    with session when is_binary(session) <- socket.assigns[:tmux_session],
         labels when is_map(labels) <- socket.assigns[:pane_labels],
         %{label: label} when is_binary(label) <-
           Map.get(labels, Casein.Labels.key(session, pane_id)) do
      label
    else
      _ -> nil
    end
  end

  defp pane_label(_socket, _pane_id), do: nil
end
