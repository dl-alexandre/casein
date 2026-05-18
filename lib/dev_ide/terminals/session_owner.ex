defmodule DevIDE.Terminals.SessionOwner do
  @moduledoc """
  Per-session terminal owner process.

  Owns one logical session (shell/execution/agent placeholder) and multiplexes
  backend output to all attached channel callers for that logical session.
  """

  use GenServer

  alias DevIDE.Terminals.{Attachment, Boundary, Session.Info}

  defstruct [
    :workspace_id,
    :info,
    :workspace_key,
    :loc,
    :host_id,
    :attachment,
    subscribers: %{},
    subscriber_refs: %{}
  ]

  def owner_key(%Info{kind: :execution} = info),
    do: {:terminal_owner, :execution, to_string(info.execution_id)}

  def owner_key(%Info{kind: :shell} = info),
    do: {:terminal_owner, :shell, to_string(info.workspace_id), to_string(info.sid || "")}

  def owner_key(%Info{kind: :agent} = info),
    do: {:terminal_owner, :agent, to_string(info.runner_id || info.id || "")}

  def owner_key(info), do: {:terminal_owner, :session, to_string(info.id || "")}

  def start_link({workspace_id, info}) do
    GenServer.start_link(__MODULE__, {workspace_id, info},
      name: {:via, Registry, {DevIDE.Terminals.Registry, owner_key(info)}}
    )
  end

  def child_spec({workspace_id, info}) do
    %{
      id: {__MODULE__, workspace_id, info.id},
      start: {__MODULE__, :start_link, [{workspace_id, info}]},
      restart: :temporary
    }
  end

  def attach(workspace_id, info, opts) when is_binary(workspace_id) do
    mode = Keyword.fetch!(opts, :mode)

    case ensure_started(workspace_id, info) do
      {:ok, pid} ->
        case GenServer.call(pid, {:attach, self(), mode, opts}) do
          {:ok, payload} -> {:ok, pid, payload}
          {:error, reason} -> {:error, reason}
        end

      {:error, {:already_started, pid}} ->
        case call_attach_direct(pid, self(), mode, opts) do
          {:ok, payload} -> {:ok, pid, payload}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def detach(owner_pid, subscriber) when is_pid(owner_pid) do
    GenServer.call(owner_pid, {:detach, subscriber})
  end

  def input(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    GenServer.cast(owner_pid, {:input, data})
    :ok
  end

  def resize(owner_pid, cols, rows)
      when is_pid(owner_pid) and is_integer(cols) and is_integer(rows) do
    GenServer.cast(owner_pid, {:resize, cols, rows})
    :ok
  end

  @impl true
  def init({workspace_id, info}) do
    {:ok,
     %__MODULE__{workspace_id: workspace_id, info: info, subscribers: %{}, subscriber_refs: %{}}}
  end

  @impl true
  def handle_call({:attach, subscriber, mode, opts}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, subscriber) do
        state
        |> update_in([Access.key!(:subscribers)], &Map.put(&1, subscriber, mode))
      else
        ref = Process.monitor(subscriber)

        state
        |> update_in([Access.key!(:subscribers)], &Map.put(&1, subscriber, mode))
        |> update_in([Access.key!(:subscriber_refs)], &Map.put(&1, ref, subscriber))
      end

    state =
      state
      |> Map.put(:workspace_key, Keyword.get(opts, :workspace_key))
      |> Map.put(:loc, Keyword.get(opts, :loc))
      |> Map.put(:host_id, Keyword.get(opts, :host_id))

    case ensure_attachment(state, mode, opts) do
      {:ok, next_state, payload} ->
        {:reply, {:ok, payload}, next_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:detach, subscriber}, _from, state) do
    next_state = prune_subscriber(state, subscriber)

    if should_stop?(next_state) do
      {:stop, :normal, :ok, next_state}
    else
      {:reply, :ok, next_state}
    end
  end

  @impl true
  def handle_cast({:input, data}, state) do
    if state.attachment do
      Attachment.send_input(state.attachment, data)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:resize, cols, rows}, state) do
    if state.attachment do
      Attachment.resize(state.attachment, cols, rows)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:term_data, _ref, data, :replay}, state) when is_binary(data) do
    broadcast_data(state.subscribers, state.info.kind, data, true)
    {:noreply, state}
  end

  def handle_info({:term_data, _ref, data}, state) when is_binary(data) do
    broadcast_data(state.subscribers, state.info.kind, data, false)
    {:noreply, state}
  end

  def handle_info({:term_data, data}, state) when is_binary(data) do
    broadcast_data(state.subscribers, state.info.kind, data, false)
    {:noreply, state}
  end

  def handle_info({:term_exit, reason}, state) do
    broadcast_exit(state.subscribers, reason)
    {:stop, :normal, state}
  end

  def handle_info({:term_exit, _ref, reason}, state) do
    broadcast_exit(state.subscribers, reason)
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    next_state = prune_subscriber_ref(state, ref)

    if should_stop?(next_state) do
      {:stop, :normal, next_state}
    else
      {:noreply, next_state}
    end
  end

  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.attachment do
      Attachment.close(state.attachment)
    end

    :ok
  end

  defp ensure_started(workspace_id, info) do
    key = owner_key(info)

    case Registry.lookup(DevIDE.Terminals.Registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {__MODULE__, {workspace_id, info}}

        DynamicSupervisor.start_child(DevIDE.Terminals.Supervisor, spec)
    end
  end

  defp call_attach_direct(pid, subscriber, mode, opts) do
    case GenServer.call(pid, {:attach, subscriber, mode, opts}) do
      {:ok, payload} -> payload
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_attachment(state, :governed, _opts) do
    commands = Boundary.command_examples()

    case state.info.kind do
      :execution when state.attachment == nil ->
        with {:ok, attachment} <- open_attachment(state) do
          {
            :ok,
            %{state | attachment: attachment},
            %{mode: "governed", commands: commands, resumable: true, session_id: state.info.id}
          }
        end

      _ ->
        {
          :ok,
          state,
          %{
            mode: "governed",
            commands: commands,
            resumable: state.info.kind != :shell,
            session_id: state.info.id
          }
        }
    end
  end

  defp ensure_attachment(state, :raw, opts) do
    with {:ok, attachment} <- open_attachment(state, opts) do
      {
        :ok,
        %{state | attachment: attachment},
        %{
          mode: "raw",
          cols: attachment.cols,
          rows: attachment.rows,
          resumable: true,
          session_id: state.info.id
        }
      }
    end
  end

  defp open_attachment(state, opts \\ []) do
    case state.info.kind do
      :shell ->
        workspace_key = state.workspace_key || Keyword.get(opts, :workspace_key)
        loc = state.loc || Keyword.get(opts, :loc)

        if is_binary(workspace_key) and is_tuple(loc) do
          Attachment.open(state.info,
            workspace_key: workspace_key,
            loc: loc,
            subscriber: self()
          )
        else
          {:error, :invalid_shell_attachment_opts}
        end

      _ ->
        Attachment.open(state.info, subscriber: self())
    end
  end

  defp broadcast_data(subscribers, :shell, data, replay) do
    normalized = IO.iodata_to_binary(data)
    payload = if replay, do: %{data: normalized, replay: true}, else: %{data: normalized}

    Enum.each(subscribers, fn
      {pid, :raw} ->
        if Process.alive?(pid), do: send(pid, {:terminal_payload, :data, payload})

      {_pid, :governed} ->
        :ok

      {pid, _} ->
        if Process.alive?(pid), do: send(pid, {:terminal_payload, :data, payload})
    end)
  end

  defp broadcast_data(subscribers, _kind, data, replay) do
    normalized = IO.iodata_to_binary(data)
    payload = if replay, do: %{data: normalized, replay: true}, else: %{data: normalized}

    Enum.each(Map.keys(subscribers), fn pid ->
      if Process.alive?(pid) do
        send(pid, {:terminal_payload, :data, payload})
      end
    end)
  end

  defp broadcast_exit(subscribers, reason) do
    Enum.each(Map.keys(subscribers), fn pid ->
      if Process.alive?(pid) do
        send(pid, {:terminal_payload, :exit, reason})
      end
    end)
  end

  defp prune_subscriber(state, subscriber) do
    case Map.get(state.subscribers, subscriber) do
      nil ->
        state

      _mode ->
        ref = find_ref_for_subscriber(state.subscriber_refs, subscriber)

        if ref do
          Process.demonitor(ref, [:flush])
        end

        %{
          state
          | subscribers: Map.delete(state.subscribers, subscriber),
            subscriber_refs: Map.delete(state.subscriber_refs, ref)
        }
    end
  end

  defp prune_subscriber_ref(state, ref) do
    case Map.get(state.subscriber_refs, ref) do
      nil ->
        state

      subscriber ->
        %{
          state
          | subscribers: Map.delete(state.subscribers, subscriber),
            subscriber_refs: Map.delete(state.subscriber_refs, ref)
        }
    end
  end

  defp find_ref_for_subscriber(mapping, subscriber) do
    Enum.find_value(mapping, fn
      {ref, ^subscriber} -> ref
      _ -> nil
    end)
  end

  defp should_stop?(state), do: state.info.kind == :execution && map_size(state.subscribers) == 0
end
