defmodule Casein.Mobile.TerminalStream do
  @moduledoc """
  Lease-owned bounded in-memory byte stream.

  Subscription and baseline capture are one serialized GenServer call, so a
  subscriber always receives its baseline before any subsequently appended
  live frame. Nothing in this process is persisted or logged.
  """

  use GenServer

  alias Casein.Mobile.TerminalProtocol
  alias Casein.Terminals

  @max_bytes TerminalProtocol.max_payload_bytes()

  def start_link(opts) do
    lease_id = Keyword.fetch!(opts, :lease_id)
    GenServer.start_link(__MODULE__, lease_id, name: via(lease_id))
  end

  def child_spec(opts) do
    lease_id = Keyword.fetch!(opts, :lease_id)

    %{
      id: {__MODULE__, lease_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def ensure_started(lease_id) when is_binary(lease_id) do
    case Registry.lookup(Casein.Terminals.Registry, stream_key(lease_id)) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(
               Casein.Terminals.Supervisor,
               {__MODULE__, lease_id: lease_id}
             ) do
          {:error, {:already_started, pid}} -> {:ok, pid}
          result -> result
        end
    end
  end

  def cutoff_lease(lease_id, reason) when is_binary(lease_id) and is_binary(reason) do
    case Registry.lookup(Casein.Terminals.Registry, stream_key(lease_id)) do
      [{pid, _}] -> cutoff(pid, reason)
      [] -> :ok
    end
  end

  def bind_owner(stream, workspace_id, info, opts \\ []) do
    GenServer.call(stream, {:bind_owner, workspace_id, info, opts}, 15_000)
  end

  def subscribe(stream, connection_generation, subscriber \\ self())
      when is_binary(connection_generation) and is_pid(subscriber) do
    GenServer.call(stream, {:subscribe, subscriber, connection_generation})
  end

  def append(stream, bytes) when is_binary(bytes), do: GenServer.call(stream, {:append, bytes})
  def cutoff(stream, reason) when is_binary(reason), do: GenServer.call(stream, {:cutoff, reason})

  def cutoff_connection(stream, subscriber, reason)
      when is_pid(subscriber) and is_binary(reason),
      do: GenServer.call(stream, {:cutoff_connection, subscriber, reason})

  def snapshot(stream), do: GenServer.call(stream, :snapshot)

  @impl true
  def init(lease_id) do
    {:ok,
     %{
       lease_id: lease_id,
       stream_generation: Ecto.UUID.generate(),
       buffer: <<>>,
       buffer_offset: 0,
       next_offset: 0,
       subscribers: %{},
       owner_pid: nil,
       owner_monitor: nil,
       topology_generation: nil,
       cutoff: nil
     }}
  end

  def handle_call({:bind_owner, _workspace_id, _info, _opts}, _from, %{cutoff: reason} = state)
      when not is_nil(reason), do: {:reply, {:error, reason}, state}

  def handle_call({:bind_owner, _workspace_id, _info, _opts}, _from, %{owner_pid: pid} = state)
      when is_pid(pid) do
    {:reply, {:ok, owner_identity(state)}, state}
  end

  def handle_call({:bind_owner, workspace_id, info, opts}, _from, state) do
    attach_opts = Keyword.merge([mode: :raw, raw: true], opts)

    case Terminals.owner_attach(workspace_id, info, attach_opts) do
      {:ok, owner_pid, _payload} ->
        monitor = Process.monitor(owner_pid)
        identity = Terminals.owner_identity(owner_pid)

        next = %{
          state
          | owner_pid: owner_pid,
            owner_monitor: monitor,
            topology_generation: identity.topology_generation
        }

        {:reply, {:ok, owner_identity(next)}, next}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:subscribe, subscriber, connection_generation}, _from, %{cutoff: nil} = state) do
    monitor = Process.monitor(subscriber)

    subscribers =
      Map.put(state.subscribers, subscriber, %{
        monitor: monitor,
        connection_generation: connection_generation
      })

    {:reply, {:ok, baseline(state, connection_generation)}, %{state | subscribers: subscribers}}
  end

  def handle_call({:subscribe, _subscriber, _connection_generation}, _from, state) do
    {:reply, {:error, state.cutoff || "stale_lease"}, state}
  end

  def handle_call({:append, bytes}, _from, %{cutoff: nil} = state) do
    {next, frames} = append_chunks(state, bytes, [])
    {:reply, {:ok, List.last(frames)}, next}
  end

  def handle_call({:append, _bytes}, _from, state),
    do: {:reply, {:error, state.cutoff || "stale_lease"}, state}

  def handle_call({:cutoff, reason}, _from, state) do
    Enum.each(state.subscribers, fn {pid, %{connection_generation: generation}} ->
      send(pid, {:mobile_terminal_cutoff, state.lease_id, generation, reason})
    end)

    {:reply, :ok, %{state | buffer: <<>>, subscribers: %{}, cutoff: reason}}
  end

  def handle_call({:cutoff_connection, subscriber, reason}, _from, state) do
    case Map.pop(state.subscribers, subscriber) do
      {%{monitor: monitor, connection_generation: generation}, subscribers} ->
        Process.demonitor(monitor, [:flush])
        send(subscriber, {:mobile_terminal_cutoff, state.lease_id, generation, reason})
        {:reply, :ok, %{state | subscribers: subscribers}}

      {nil, _subscribers} ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _reason}, state) do
    cond do
      state.owner_pid == pid and state.owner_monitor == monitor ->
        {:noreply, cutoff_state(state, "owner_unavailable")}

      true ->
        subscribers =
          case Map.get(state.subscribers, pid) do
            %{monitor: ^monitor} -> Map.delete(state.subscribers, pid)
            _other -> state.subscribers
          end

        {:noreply, %{state | subscribers: subscribers}}
    end
  end

  def handle_info({:terminal_payload, :data, %{data: bytes}}, %{cutoff: nil} = state)
      when is_binary(bytes) do
    {:noreply, append_bytes(state, bytes)}
  end

  def handle_info({:terminal_payload, :exit, _reason}, state),
    do: {:noreply, cutoff_state(state, "owner_unavailable")}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{owner_pid: owner_pid}) when is_pid(owner_pid) do
    Terminals.owner_detach(owner_pid, self())
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp baseline(state, connection_generation) do
    %{
      lease_id: state.lease_id,
      connection_generation: connection_generation,
      stream_generation: state.stream_generation,
      offset: state.buffer_offset,
      next_offset: state.next_offset,
      bytes: state.buffer,
      truncated: state.buffer_offset > 0
    }
  end

  defp retain_tail(bytes, next_offset) when byte_size(bytes) <= @max_bytes,
    do: {bytes, next_offset - byte_size(bytes)}

  defp retain_tail(bytes, next_offset) do
    excess = byte_size(bytes) - @max_bytes
    {:binary.part(bytes, excess, @max_bytes), next_offset - @max_bytes}
  end

  defp append_bytes(state, bytes) do
    {next, _frames} = append_chunks(state, bytes, [])
    next
  end

  defp append_chunks(state, <<>>, frames), do: {state, Enum.reverse(frames)}

  defp append_chunks(state, bytes, frames) do
    take = min(byte_size(bytes), @max_bytes)
    <<chunk::binary-size(^take), rest::binary>> = bytes
    offset = state.next_offset
    next_offset = offset + byte_size(chunk)
    {buffer, buffer_offset} = retain_tail(state.buffer <> chunk, next_offset)

    frame = %{
      lease_id: state.lease_id,
      stream_generation: state.stream_generation,
      offset: offset,
      next_offset: next_offset,
      bytes: chunk
    }

    Enum.each(state.subscribers, fn {pid, %{connection_generation: generation}} ->
      send(pid, {:mobile_terminal_output, Map.put(frame, :connection_generation, generation)})
    end)

    next = %{state | buffer: buffer, buffer_offset: buffer_offset, next_offset: next_offset}
    append_chunks(next, rest, [frame | frames])
  end

  defp cutoff_state(state, reason) do
    Enum.each(state.subscribers, fn {pid, %{connection_generation: generation}} ->
      send(pid, {:mobile_terminal_cutoff, state.lease_id, generation, reason})
    end)

    %{state | buffer: <<>>, subscribers: %{}, cutoff: reason}
  end

  defp owner_identity(state) do
    %{
      owner_pid: state.owner_pid,
      topology_generation: state.topology_generation,
      stream_generation: state.stream_generation
    }
  end

  defp via(lease_id),
    do: {:via, Registry, {Casein.Terminals.Registry, stream_key(lease_id)}}

  defp stream_key(lease_id), do: {:mobile_terminal_stream, lease_id}
end
