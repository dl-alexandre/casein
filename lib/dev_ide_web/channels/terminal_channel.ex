defmodule DevIdeWeb.TerminalChannel do
  @moduledoc """
  Bidirectional terminal stream for any session — workspace shell or fleet
  execution. Topic: `terminal:<workspace_id>:<sid>`.

  The channel is now a thin transport for session owners. It resolves the
  logical session and delegates attachment/input/resize behavior to
  `DevIDE.Terminals.SessionOwner`.

  Authorization: the underlying Phoenix.Socket already authenticated the user
  token. Every join re-checks workspace path safety against the manager.
  """

  use Phoenix.Channel

  alias DevIDE.Terminals
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Terminals.Session.Info
  alias DevIDE.Workspaces
  alias DevIdeWeb.Plugs.ForwardAuth

  @impl true
  def join("terminal:" <> rest, params, socket) do
    user = socket.assigns[:current_user] || %{}

    with [workspace_id, sid] <- String.split(rest, ":", parts: 2),
         {:ok, ws} <- Workspaces.get(workspace_id, user[:email]),
         :ok <- authorize_owner(ws, user),
         {:ok, %Info{} = info} <- Terminals.resolve(sid),
         {:ok, mode} <- Terminals.attachment_policy(info, Boundary.normalize_mode(params["mode"])) do
      host_id = host_id(params)

      socket =
        socket
        |> assign(:workspace_id, workspace_id)
        |> assign(:host_id, host_id)
        |> assign(:terminal_sid, sid)
        |> assign(:terminal_mode, mode)

      attach_owner_mode(info, mode, ws, socket)
    else
      :error -> {:error, %{reason: "invalid session"}}
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "invalid session"}}
    end
  end

  # Workspace ownership gate — see WorkspaceLive.Show.authorize_owner/2.
  defp authorize_owner(ws, user) do
    if not ForwardAuth.enabled?() or Workspaces.owns?(ws, user[:username]),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp attach_owner_mode(%Info{} = info, :governed, _ws, socket) do
    case Terminals.owner_attach(
           socket.assigns.workspace_id,
           info,
           mode: :governed,
           host_id: socket.assigns.host_id,
           workspace_key: socket.assigns.workspace_id,
           session_id: socket.assigns.terminal_sid
         ) do
      {:ok, owner_pid, attach_payload} ->
        {:ok, attach_payload, assign(socket, :terminal_owner_pid, owner_pid)}

      {:error, reason} ->
        {:error, %{reason: format(reason)}}
    end
  end

  defp attach_owner_mode(%Info{kind: :shell} = info, :raw, ws, socket) do
    with :ok <-
           Boundary.authorize_raw(socket.assigns.workspace_id,
             actor_id: actor_id(socket),
             host_id: socket.assigns.host_id,
             session_id: info.sid
           ),
         {:ok, loc} <- Workspaces.safe_host_loc(ws),
         {:ok, owner_pid, attach_payload} <-
           Terminals.owner_attach(
             socket.assigns.workspace_id,
             info,
             mode: :raw,
             host_id: socket.assigns.host_id,
             workspace_key: ws.name || ws.id,
             loc: loc,
             session_id: socket.assigns.terminal_sid
           ) do
      {:ok, attach_payload, assign(socket, :terminal_owner_pid, owner_pid)}
    else
      {:error, reason} -> {:error, %{reason: format(reason)}}
      _ -> {:error, %{reason: "raw terminal unavailable"}}
    end
  end

  # =====================
  # Incoming Events
  # =====================

  @impl true
  def handle_in(
        "input",
        %{"data" => data},
        %{assigns: %{terminal_mode: :raw, terminal_owner_pid: owner_pid}} = socket
      )
      when is_binary(data) do
    Terminals.owner_input(owner_pid, data)
    {:noreply, socket}
  end

  def handle_in("input", _params, socket) do
    {:reply, {:error, %{reason: Boundary.format_reason(:raw_terminal_disabled)}}, socket}
  end

  def handle_in("command", %{"line" => line}, %{assigns: %{terminal_mode: :governed}} = socket)
      when is_binary(line) do
    case Boundary.submit_governed(socket.assigns.workspace_id, line,
           actor_id: actor_id(socket),
           host_id: socket.assigns.host_id,
           session_id: socket.assigns.terminal_sid
         ) do
      {:ok, %{kind: :inspection} = result} ->
        {:reply,
         {:ok,
          %{
            status: result.status,
            line: result.line,
            exit_code: result.exit_code,
            output: result.output,
            output_truncated: result.output_truncated
          }}, socket}

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
        %{assigns: %{terminal_mode: :raw, terminal_owner_pid: owner_pid}} = socket
      )
      when is_integer(c) and is_integer(r) do
    Terminals.owner_resize(owner_pid, c, r)
    {:noreply, socket}
  end

  def handle_in(_, _, socket), do: {:noreply, socket}

  # =====================
  # Owner events
  # =====================

  @impl true
  def handle_info({:terminal_payload, :data, payload}, socket) do
    push(socket, "data", payload)
    {:noreply, socket}
  end

  def handle_info({:terminal_payload, :exit, reason}, socket) do
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{terminal_owner_pid: owner_pid}}) do
    Terminals.owner_detach(owner_pid, self())
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp format(:forbidden), do: "that workspace belongs to another user"
  defp format(:missing_path), do: "workspace has no host path"
  defp format(:outside_root), do: "workspace path outside allowed roots"
  defp format(:requires_local_host), do: Boundary.format_reason(:requires_local_host)
  defp format(:requires_manual_mode), do: Boundary.format_reason(:requires_manual_mode)
  defp format(:invalid_shell_attachment_opts), do: "missing shell attachment options"
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
