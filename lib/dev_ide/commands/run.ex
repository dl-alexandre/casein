defmodule DevIDE.Commands.Run do
  @moduledoc """
  One in-flight workspace command. Keyed by workspace id in
  `DevIDE.Commands.Registry`; supervised by `DevIDE.Commands.Supervisor`.

  Lifecycle:
    :running → :succeeded | :failed | :timed_out

  After a terminal status, the process lingers for 2 minutes so a
  reconnecting LiveView can pick up the result. `start/3` will tear down a
  terminal-status process and replace it, so the linger never blocks a new run.

  Hard timeout is configurable per call (default
  `:dev_ide, :command_timeout_ms` or 30 minutes). On timeout the OS process
  is killed and `status` becomes `:timed_out`.
  """

  use GenServer
  alias DevIDE.Commands
  alias DevIDE.Commands.History

  @max_buffer_bytes 256 * 1024
  @default_timeout_ms 30 * 60 * 1000

  ## API

  def child_spec({_workspace_id, _root, _id, _opts} = arg) do
    %{id: {__MODULE__, arg}, start: {__MODULE__, :start_link, [arg]}, restart: :temporary}
  end

  def start_link({workspace_id, root, id, opts}) do
    GenServer.start_link(__MODULE__, {workspace_id, root, id, opts}, name: via(workspace_id))
  end

  def via(workspace_id),
    do: {:via, Registry, {DevIDE.Commands.Registry, workspace_id}}

  def whereis(workspace_id) do
    case Registry.lookup(DevIDE.Commands.Registry, workspace_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Start a new run.

  If a previous Run process for this workspace is still around but in a
  terminal status (`:succeeded`/`:failed`/`:timed_out`), it is stopped and
  replaced. Only an actively running command blocks a new start.
  """
  def start(workspace_id, root, id, opts \\ []) do
    cond do
      not Commands.allowed?(id) -> {:error, :not_allowed}
      not File.dir?(root) -> {:error, :no_root}
      true -> ensure_fresh(workspace_id, root, id, opts)
    end
  end

  defp ensure_fresh(workspace_id, root, id, opts) do
    case whereis(workspace_id) do
      :error ->
        spawn_run(workspace_id, root, id, opts)

      {:ok, pid} ->
        case status(pid) do
          :running ->
            {:error, :already_running}

          _terminal ->
            stop_existing(pid)
            spawn_run(workspace_id, root, id, opts)
        end
    end
  end

  defp spawn_run(workspace_id, root, id, opts) do
    DynamicSupervisor.start_child(
      DevIDE.Commands.Supervisor,
      {__MODULE__, {workspace_id, root, id, opts}}
    )
  end

  defp status(pid) do
    case GenServer.call(pid, :state, 1_000) do
      %{status: s} -> s
    end
  catch
    :exit, _ -> :running
  end

  defp stop_existing(pid) do
    ref = Process.monitor(pid)
    GenServer.stop(pid, :normal, 1_000)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_500 -> :ok
    end
  end

  def state(pid), do: GenServer.call(pid, :state)
  def subscribe(pid), do: GenServer.call(pid, {:subscribe, self()})
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  ## Callbacks

  @impl true
  def init({workspace_id, root, id, opts}) do
    {:ok, argv} = Commands.argv_for(id)
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    case Commands.spawn(root, argv, self()) do
      {:ok, ref, handle} ->
        timer_ref = Process.send_after(self(), :hard_timeout, timeout_ms)
        started_at = DateTime.utc_now()

        history_id =
          case History.start_run(%{
                 workspace_id: workspace_id,
                 actor_id: Keyword.get(opts, :actor_id),
                 command_id: id,
                 started_at: started_at,
                 metadata: Keyword.get(opts, :metadata, %{})
               }) do
            {:ok, %{id: hid}} -> hid
            _ -> nil
          end

        state = %{
          workspace_id: workspace_id,
          id: id,
          argv: argv,
          root: root,
          ref: ref,
          handle: handle,
          status: :running,
          started_at: started_at,
          finished_at: nil,
          exit_code: nil,
          buffer: "",
          subscriber: nil,
          subscriber_mon: nil,
          timer_ref: timer_ref,
          timeout_ms: timeout_ms,
          history_id: history_id
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, snapshot(state), state}

  def handle_call({:subscribe, pid}, _from, state) do
    if state.subscriber_mon, do: Process.demonitor(state.subscriber_mon, [:flush])
    mon = Process.monitor(pid)
    {:reply, {:ok, snapshot(state)}, %{state | subscriber: pid, subscriber_mon: mon}}
  end

  @impl true
  def handle_cast(:cancel, %{handle: h, status: :running} = state) do
    Commands.kill(h)
    {:noreply, state}
  end

  def handle_cast(:cancel, state), do: {:noreply, state}

  @impl true
  def handle_info({:cmd_data, ref, stream, data}, %{ref: ref} = state) do
    bin = IO.iodata_to_binary(data)
    state = update_in(state.buffer, fn b -> cap(b <> bin) end)
    if state.subscriber, do: send(state.subscriber, {:run_data, state.workspace_id, stream, bin})
    {:noreply, state}
  end

  def handle_info({:cmd_exit, ref, code}, %{ref: ref, status: :running} = state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    status = if code == 0, do: :succeeded, else: :failed
    state = finish(state, status, code)
    Process.send_after(self(), :linger_done, :timer.minutes(2))
    {:noreply, state}
  end

  def handle_info({:cmd_exit, _, _}, state), do: {:noreply, state}

  def handle_info(:hard_timeout, %{status: :running} = state) do
    Commands.kill(state.handle)
    state = finish(state, :timed_out, :timeout)
    Process.send_after(self(), :linger_done, :timer.minutes(2))
    {:noreply, state}
  end

  def handle_info(:hard_timeout, state), do: {:noreply, state}
  def handle_info(:linger_done, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscriber: pid} = state) do
    {:noreply, %{state | subscriber: nil, subscriber_mon: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp finish(state, status, exit_code) do
    finished_at = DateTime.utc_now()
    state = %{state | status: status, finished_at: finished_at, exit_code: exit_code}

    if state.history_id do
      _ =
        History.finish_run(state.history_id, %{
          status: status,
          exit_code: exit_code,
          finished_at: finished_at,
          started_at: state.started_at,
          output: state.buffer
        })
    end

    if state.subscriber,
      do: send(state.subscriber, {:run_exit, state.workspace_id, exit_code, status})

    state
  end

  defp default_timeout_ms,
    do: Application.get_env(:dev_ide, :command_timeout_ms, @default_timeout_ms)

  defp snapshot(state) do
    state
    |> Map.take([
      :workspace_id,
      :id,
      :argv,
      :status,
      :started_at,
      :finished_at,
      :exit_code,
      :buffer
    ])
    |> Map.put(:run_id, state.history_id)
  end

  defp cap(buf) when byte_size(buf) <= @max_buffer_bytes, do: buf

  defp cap(buf) do
    drop = byte_size(buf) - @max_buffer_bytes
    <<_::binary-size(drop), tail::binary>> = buf
    "[…truncated]\n" <> tail
  end
end
