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
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Terminals.Session

  @impl true
  def join("terminal:" <> rest, params, socket) do
    with [workspace_id, sid] <- String.split(rest, ":", parts: 2),
         {:ok, ws} <- Workspaces.get(workspace_id) do
      mode = Boundary.normalize_mode(params["mode"])
      host_id = host_id(params)

      join_terminal(mode, ws, workspace_id, sid, host_id, socket)
    else
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "invalid topic"}}
    end
  end

  defp join_terminal(:governed, _ws, workspace_id, _sid, host_id, socket) do
    socket =
      socket
      |> assign(:terminal_mode, :governed)
      |> assign(:workspace_id, workspace_id)
      |> assign(:host_id, host_id)

    {:ok,
     %{
       mode: "governed",
       commands: Boundary.command_examples()
     }, socket}
  end

  defp join_terminal(:raw, ws, workspace_id, sid, host_id, socket) do
    with :ok <-
           Boundary.authorize_raw(workspace_id,
             actor_id: actor_id(socket),
             host_id: host_id
           ),
         {:ok, cwd} <- Workspaces.safe_host_path(ws),
         {:ok, session_pid} <- Session.ensure_started(ws.name || ws.id, sid, cwd),
         {:ok, ref, cols, rows} <- Session.subscribe(session_pid) do
      socket =
        socket
        |> assign(:terminal_mode, :raw)
        |> assign(:session_pid, session_pid)
        |> assign(:session_ref, ref)
        |> assign(:workspace_id, workspace_id)
        |> assign(:host_id, host_id)

      {:ok, %{mode: "raw", cols: cols, rows: rows}, socket}
    else
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "raw terminal unavailable"}}
    end
  end

  @impl true
  def handle_in("input", %{"data" => data}, %{assigns: %{terminal_mode: :raw}} = socket)
      when is_binary(data) do
    Session.input(socket.assigns.session_pid, data)
    {:noreply, socket}
  end

  def handle_in("input", %{"data" => data}, socket) when is_binary(data) do
    {:reply, {:error, %{reason: Boundary.format_reason(:raw_terminal_disabled)}}, socket}
  end

  def handle_in("command", %{"line" => line}, %{assigns: %{terminal_mode: :governed}} = socket)
      when is_binary(line) do
    case Boundary.submit_governed(socket.assigns.workspace_id, line,
           actor_id: actor_id(socket),
           host_id: socket.assigns.host_id
         ) do
      {:ok, assignment} ->
        {:reply, {:ok, %{status: "queued", assignment: assignment}}, socket}

      {:error, :blank} ->
        {:reply, {:ok, %{status: "blank"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{reason: Boundary.format_reason(reason)}}, socket}
    end
  end

  def handle_in("command", _params, socket) do
    {:reply, {:error, %{reason: "command submission requires governed terminal mode"}}, socket}
  end

  def handle_in(
        "resize",
        %{"cols" => c, "rows" => r},
        %{assigns: %{terminal_mode: :raw}} = socket
      )
      when is_integer(c) and is_integer(r) do
    Session.resize(socket.assigns.session_pid, c, r)
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => c, "rows" => r}, socket)
      when is_integer(c) and is_integer(r) do
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
  defp format(:requires_local_host), do: Boundary.format_reason(:requires_local_host)
  defp format(:requires_manual_mode), do: Boundary.format_reason(:requires_manual_mode)
  defp format(other), do: inspect(other)

  defp host_id(params) do
    case params["host_id"] do
      value when is_binary(value) and value != "" -> value
      _ -> "local"
    end
  end

  defp actor_id(%{assigns: %{current_user: %{id: id}}}), do: id
  defp actor_id(_), do: "terminal"
end
