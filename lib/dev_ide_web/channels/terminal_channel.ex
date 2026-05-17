defmodule DevIdeWeb.TerminalChannel do
  @moduledoc """
  Bidirectional terminal stream for any session — workspace shell or fleet
  execution. Topic: `terminal:<workspace_id>:<sid>`.

  Phase 2: the channel resolves the session via `Terminals.resolve/1` and
  dispatches on `info.kind`. It never branches on a client-supplied session
  kind. All I/O flows through a single `%Attachment{}` handle.

  Authorization: the underlying Phoenix.Socket already authenticated the user
  token. Every join re-checks workspace path safety against the manager.
  """

  use Phoenix.Channel
  require Logger

  alias DevIDE.Terminals
  alias DevIDE.Terminals.{Attachment, Boundary}
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
        |> assign(:session_info, info)

      attach_session(info, mode, ws, socket)
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

  # Fleet executions: governed-only, defer streamer open to after_join so the
  # caller gets the join reply promptly.
  defp attach_session(%Info{kind: :execution}, :governed, _ws, socket) do
    send(self(), :open_attachment)

    {:ok, %{mode: "governed", commands: Boundary.command_examples()},
     assign(socket, :terminal_mode, :governed)}
  end

  # Governed shell: no attachment yet, commands go through Boundary.
  defp attach_session(%Info{kind: :shell}, :governed, _ws, socket) do
    {:ok, %{mode: "governed", commands: Boundary.command_examples()},
     assign(socket, :terminal_mode, :governed)}
  end

  # Raw shell: open immediately so we can return cols/rows in the join reply.
  defp attach_session(%Info{kind: :shell} = info, :raw, ws, socket) do
    with :ok <-
           Boundary.authorize_raw(socket.assigns.workspace_id,
             actor_id: actor_id(socket),
             host_id: socket.assigns.host_id,
             session_id: info.sid
           ),
         {:ok, loc} <- Workspaces.safe_host_loc(ws),
         {:ok, %Attachment{pid: pid} = att} <-
           Terminals.attach(info, workspace_key: ws.name || ws.id, loc: loc, subscriber: self()) do
      ref = Process.monitor(pid)

      socket =
        socket
        |> assign(:terminal_mode, :raw)
        |> assign(:attachment, att)
        |> assign(:attachment_mon, ref)

      {:ok, %{mode: "raw", cols: att.cols, rows: att.rows}, socket}
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
        %{assigns: %{attachment: %Attachment{} = att}} = socket
      )
      when is_binary(data) do
    Attachment.send_input(att, data)
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

  def handle_in("resize", %{"cols" => c, "rows" => r}, %{assigns: %{attachment: att}} = socket)
      when is_integer(c) and is_integer(r) do
    Attachment.resize(att, c, r)
    {:noreply, socket}
  end

  def handle_in(_, _, socket), do: {:noreply, socket}

  # =====================
  # Info Messages
  # =====================

  @impl true
  def handle_info(:open_attachment, %{assigns: %{session_info: info}} = socket) do
    case Terminals.attach(info, subscriber: self()) do
      {:ok, %Attachment{pid: pid} = att} ->
        ref = Process.monitor(pid)

        {:noreply,
         socket
         |> assign(:attachment, att)
         |> assign(:attachment_mon, ref)}

      {:error, reason} ->
        push(socket, "exit", %{reason: inspect(reason)})
        {:stop, :normal, socket}
    end
  end

  # Backend streamer (or shell Session) died — surface to client and stop.
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{attachment_mon: ref}} = socket
      ) do
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  # FleetSessionStreamer / RemoteOutputStreamer message (no ref).
  def handle_info({:term_data, data}, socket) when is_binary(data) do
    push(socket, "data", %{data: data})
    {:noreply, socket}
  end

  # Streamer-originated exit (no ref). Carries a semantic reason like
  # `:runner_unreachable` or `:execution_finished` — preserve it rather than
  # letting the subsequent DOWN monitor swallow it as `:normal`.
  def handle_info({:term_exit, reason}, socket) do
    push(socket, "exit", %{reason: to_string(reason)})
    {:stop, :normal, socket}
  end

  # Shell Session message (ref-tagged).
  def handle_info(
        {:term_data, ref, data},
        %{assigns: %{attachment: %Attachment{ref: ref}}} = socket
      ) do
    push(socket, "data", %{data: IO.iodata_to_binary(data)})
    {:noreply, socket}
  end

  def handle_info(
        {:term_exit, ref, reason},
        %{assigns: %{attachment: %Attachment{ref: ref}}} = socket
      ) do
    push(socket, "exit", %{reason: inspect(reason)})
    {:stop, :normal, socket}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, %{assigns: %{attachment: %Attachment{} = att}}) do
    Attachment.close(att)
    :ok
  end

  def terminate(_reason, _socket), do: :ok

  defp format(:forbidden), do: "that workspace belongs to another user"
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
