defmodule CaseinWeb.MobileTerminalChannel do
  @moduledoc "Authenticated read-only transport for one mobile terminal lease."

  use Phoenix.Channel

  alias Casein.DeviceLinks

  alias Casein.Mobile.{
    TerminalChildGrants,
    TerminalPolicy,
    TerminalProtocol,
    TerminalSessions,
    TerminalStream
  }

  alias Casein.Terminals.Session.Info

  @validation_interval 1_000

  @impl true
  def join("mobile_terminal:" <> lease_id, params, socket) do
    with :ok <- device_socket?(socket),
         {:ok, connection_generation, raw_grant} <- join_params(params),
         {:ok, lease} <- TerminalSessions.get(lease_id) |> present_lease(),
         context <- context(socket, lease),
         :ok <- DeviceLinks.authorize_link(lease.device_link_id, context),
         :ok <- TerminalPolicy.authorize(context),
         {:ok, ^lease} <- TerminalSessions.authorize_read(lease_id, context),
         {:ok, grant} <-
           TerminalChildGrants.begin_use(raw_grant, context, connection_generation),
         {:ok, stream} <- TerminalStream.ensure_started(lease.id),
         info <- Info.new_shell(lease.workspace_id, lease.sid),
         {:ok, identity} <-
           TerminalStream.bind_owner(stream, lease.workspace_id, info,
             workspace_key: lease.workspace_key,
             loc: {:local, lease.workspace_root}
           ),
         true <- identity.topology_generation == grant.topology_generation,
         {:ok, baseline} <- TerminalStream.subscribe(stream, connection_generation),
         :ok <- DeviceLinks.subscribe_revocation(lease.device_link_id),
         :ok <- DeviceLinks.authorize_link(lease.device_link_id, context) do
      Process.send_after(self(), :validate_mobile_terminal, @validation_interval)

      socket =
        socket
        |> assign(:terminal_lease, lease)
        |> assign(:terminal_grant, grant)
        |> assign(
          :terminal_context,
          Map.put(context, :topology_generation, identity.topology_generation)
        )
        |> assign(:terminal_stream, stream)
        |> assign(:connection_generation, connection_generation)

      {:ok, TerminalProtocol.baseline(payload_fields(baseline, lease)), socket}
    else
      false -> {:error, TerminalProtocol.error("topology_mismatch")}
      {:error, reason} -> {:error, TerminalProtocol.error(reason_code(reason))}
      _ -> {:error, TerminalProtocol.error("unauthorized")}
    end
  end

  @impl true
  def handle_in(event, _params, socket)
      when event in ["terminal_input", "terminal_paste", "terminal_query"] do
    {:reply, {:error, TerminalProtocol.error("read_only")}, socket}
  end

  def handle_in(_event, _params, socket),
    do: {:reply, {:error, TerminalProtocol.error("invalid_payload")}, socket}

  @impl true
  def handle_info({:mobile_terminal_output, frame}, socket) do
    # Output is already serialized behind TerminalStream.cutoff/2. Keep this
    # hot path allocation-only; durable grant/policy/topology checks run on the
    # bounded validation tick and all control-plane mutations cut off the stream
    # before changing the lease.
    push(
      socket,
      "terminal_output",
      TerminalProtocol.output(payload_fields(frame, socket.assigns.terminal_lease))
    )

    {:noreply, socket}
  end

  def handle_info({:mobile_terminal_cutoff, lease_id, generation, reason}, socket) do
    push(
      socket,
      "terminal_cutoff",
      TerminalProtocol.cutoff(lease_id, generation, reason_code(reason))
    )

    {:stop, :normal, socket}
  end

  def handle_info({:device_link_revoked, device_link_id}, socket)
      when device_link_id == socket.assigns.terminal_lease.device_link_id,
      do: cutoff(socket, :grant_revoked)

  def handle_info(:validate_mobile_terminal, socket) do
    case authorize_live(socket) do
      :ok ->
        Process.send_after(self(), :validate_mobile_terminal, @validation_interval)
        {:noreply, socket}

      {:error, {:grant, reason}} ->
        cutoff_connection(socket, reason)

      {:error, reason} ->
        cutoff(socket, reason)
    end
  end

  defp authorize_live(socket) do
    lease = socket.assigns.terminal_lease
    context = socket.assigns.terminal_context

    with :ok <- DeviceLinks.authorize_link(lease.device_link_id, context),
         :ok <- TerminalPolicy.authorize(context),
         {:ok, _lease} <- TerminalSessions.authorize_read(lease.id, context) do
      case TerminalChildGrants.authorize(
             socket.assigns.terminal_grant,
             context,
             socket.assigns.connection_generation
           ) do
        :ok -> :ok
        {:error, reason} -> {:error, {:grant, reason}}
      end
    end
  end

  defp cutoff(socket, reason) do
    code = reason_code(reason)
    :ok = TerminalStream.cutoff(socket.assigns.terminal_stream, code)

    push(
      socket,
      "terminal_cutoff",
      TerminalProtocol.cutoff(
        socket.assigns.terminal_lease.id,
        socket.assigns.connection_generation,
        code
      )
    )

    {:stop, :normal, socket}
  end

  defp cutoff_connection(socket, reason) do
    code = reason_code(reason)
    :ok = TerminalStream.cutoff_connection(socket.assigns.terminal_stream, self(), code)

    push(
      socket,
      "terminal_cutoff",
      TerminalProtocol.cutoff(
        socket.assigns.terminal_lease.id,
        socket.assigns.connection_generation,
        code
      )
    )

    {:stop, :normal, socket}
  end

  defp payload_fields(frame, lease),
    do: Map.put(frame, :lifecycle_generation, lease.lifecycle_generation)

  defp context(socket, lease) do
    %{
      user_id: socket.assigns.current_user.id,
      device_link_id: socket.assigns.device_link_id,
      origin_id: socket.assigns.mobile_origin_id,
      origin_generation: socket.assigns.mobile_origin_generation,
      workspace_id: socket.assigns.pairing_workspace_id,
      lease_id: lease.id,
      lifecycle_generation: lease.lifecycle_generation,
      sid: lease.sid,
      tmux_session: lease.tmux_session,
      pane_id: lease.pane_id,
      pane_role: lease.pane_role
    }
  end

  defp device_socket?(%{assigns: %{socket_credential: :device_link_token}}), do: :ok
  defp device_socket?(_socket), do: {:error, :unauthorized}

  defp join_params(%{"child_grant" => grant, "connection_generation" => generation})
       when is_binary(grant) and grant != "" and is_binary(generation) and generation != "",
       do: {:ok, generation, grant}

  defp join_params(_params), do: {:error, :invalid_payload}
  defp present_lease(nil), do: {:error, :not_found}
  defp present_lease(lease), do: {:ok, lease}

  defp reason_code(reason) when is_binary(reason) do
    if reason in TerminalProtocol.error_codes(), do: reason, else: "unavailable"
  end

  defp reason_code(reason) when is_atom(reason), do: reason |> Atom.to_string() |> reason_code()
  defp reason_code(_reason), do: "unavailable"
end
