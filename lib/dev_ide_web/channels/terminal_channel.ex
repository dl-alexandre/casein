defmodule DevIdeWeb.TerminalChannel do
  @moduledoc """
  Bidirectional terminal stream for a workspace tmux session.

  Topic: `terminal:<workspace_id>:<sid>` — `sid` is a per-tab id from the
  browser hook. The Session GenServer is keyed on `(workspace_name, sid)` so
  reload of the same browser tab reattaches; a new tab gets a new tmux session.

  Authorization: the underlying Phoenix.Socket already authenticated the user
  token. Every join re-checks workspace path safety against the manager.
  """

  use Phoenix.Channel
  require Logger

  alias DevIDE.Workspaces
  alias DevIDE.Terminals.Session

  @impl true
  def join("terminal:" <> rest, _params, socket) do
    with [workspace_id, sid] <- String.split(rest, ":", parts: 2),
         {:ok, ws} <- Workspaces.get(workspace_id),
         {:ok, cwd} <- Workspaces.safe_host_path(ws),
         {:ok, session_pid} <- Session.ensure_started(ws.name || ws.id, sid, cwd),
         {:ok, ref, cols, rows} <- Session.subscribe(session_pid) do
      socket =
        socket
        |> assign(:session_pid, session_pid)
        |> assign(:session_ref, ref)
        |> assign(:workspace_id, workspace_id)

      {:ok, %{cols: cols, rows: rows}, socket}
    else
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "invalid topic"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    Session.input(socket.assigns.session_pid, data)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => c, "rows" => r}, socket)
      when is_integer(c) and is_integer(r) do
    Session.resize(socket.assigns.session_pid, c, r)
    {:noreply, socket}
  end

  def handle_in(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:term_data, ref, data}, %{assigns: %{session_ref: ref}} = socket) do
    push(socket, "data", %{data: IO.iodata_to_binary(data)})
    {:noreply, socket}
  end

  def handle_info({:term_exit, ref, reason}, %{assigns: %{session_ref: ref}} = socket) do
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp format(:missing_path), do: "workspace has no host path"
  defp format(:outside_root), do: "workspace path outside allowed roots"
  defp format(other), do: inspect(other)
end
