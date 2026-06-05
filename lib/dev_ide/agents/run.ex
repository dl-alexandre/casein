defmodule DevIDE.Agents.Run do
  @moduledoc """
  One in-flight review-mode agent run, keyed by workspace id.

  Mirrors `DevIDE.Commands.Run` (supervisor + linger + replace-on-terminal +
  hard timeout). Distinct registry so command runs and agent runs don't
  contend for the same slot.

  argv is fixed by `DevIDE.Agents.ReviewCommand` — there is no path through
  this module to execute an arbitrary command, send a prompt, or apply a
  patch. It only spawns, observes, and cancels.
  """

  use GenServer
  alias DevIDE.Agents.{ReviewCommand, Capability}
  alias DevIDE.Commands

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
    do: {:via, Registry, {DevIDE.Agents.Registry, workspace_id}}

  def whereis(workspace_id) do
    case Registry.lookup(DevIDE.Agents.Registry, workspace_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Start a review-mode run. Refuses if the command id is not in the
  allowlist or if `requires` is not satisfied by the supplied capability list.
  """
  @spec start(String.t(), String.t(), ReviewCommand.id(), [Capability.t()], keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start(workspace_id, root, id, caps, opts \\ []) do
    with {:ok, %ReviewCommand{} = cmd} <- ReviewCommand.fetch(id),
         true <- ReviewCommand.available?(cmd, caps) || {:error, :requires_not_met},
         true <- File.dir?(root) || {:error, :no_root} do
      ensure_fresh(workspace_id, root, cmd, opts)
    else
      :error -> {:error, :not_allowed}
      {:error, _} = err -> err
    end
  end

  defp ensure_fresh(workspace_id, root, cmd, opts) do
    case whereis(workspace_id) do
      :error ->
        spawn_run(workspace_id, root, cmd, opts)

      {:ok, pid} ->
        case status(pid) do
          :running ->
            {:error, :already_running}

          _terminal ->
            stop_existing(pid)
            spawn_run(workspace_id, root, cmd, opts)
        end
    end
  end

  defp spawn_run(workspace_id, root, %ReviewCommand{} = cmd, opts) do
    DynamicSupervisor.start_child(
      DevIDE.Agents.Supervisor,
      {__MODULE__, {workspace_id, root, cmd, opts}}
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
  def init({workspace_id, root, %ReviewCommand{} = cmd, opts}) do
    timeout_ms = Keyword.get(opts, :timeout_ms, default_timeout_ms())

    case Commands.spawn(root, cmd.argv, self()) do
      {:ok, ref, handle} ->
        timer_ref = Process.send_after(self(), :hard_timeout, timeout_ms)

        state = %{
          workspace_id: workspace_id,
          command: cmd,
          root: root,
          ref: ref,
          handle: handle,
          status: :running,
          started_at: DateTime.utc_now(),
          finished_at: nil,
          exit_code: nil,
          buffer: "",
          subscriber: nil,
          subscriber_mon: nil,
          timer_ref: timer_ref,
          timeout_ms: timeout_ms
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

    if state.subscriber,
      do: send(state.subscriber, {:agent_run_data, state.workspace_id, stream, bin})

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
    state = %{state | status: status, finished_at: DateTime.utc_now(), exit_code: exit_code}

    if state.subscriber,
      do: send(state.subscriber, {:agent_run_exit, state.workspace_id, exit_code, status})

    state
  end

  defp default_timeout_ms,
    do: Application.get_env(:dev_ide, :agent_run_timeout_ms, @default_timeout_ms)

  defp snapshot(state) do
    %{
      workspace_id: state.workspace_id,
      id: state.command.id,
      argv: state.command.argv,
      output_kind: state.command.output_kind,
      status: state.status,
      started_at: state.started_at,
      finished_at: state.finished_at,
      exit_code: state.exit_code,
      buffer: state.buffer
    }
  end

  defp cap(buf) when byte_size(buf) <= @max_buffer_bytes, do: buf

  defp cap(buf) do
    tail = binary_part(buf, byte_size(buf) - @max_buffer_bytes, @max_buffer_bytes)
    "[…truncated]\n" <> tail
  end
end
