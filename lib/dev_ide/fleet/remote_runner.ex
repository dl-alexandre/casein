defmodule DevIDE.Fleet.RemoteRunner do
  @moduledoc """
  Standalone runner runtime.

  The process registers a runner identity, heartbeats, polls for controller
  offers, renews active leases, and reports execution state through protocol
  envelopes. It is suitable for `mix jx.runner.start` and for localhost tests.
  """

  use GenServer

  require Logger

  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.RemoteRunner.Executor

  @default_heartbeat_ms 5_000
  @default_poll_ms 250
  @default_renew_ms 5_000

  # Cap the reschedule interval when heartbeat/poll keep failing so an
  # unreachable or revoked controller cannot be hammered at the fixed rate.
  @max_backoff_ms 30_000

  @type state :: %{
          transport: module(),
          transport_state: map(),
          runner_id: String.t(),
          active_offer: map() | nil,
          active_lease_id: String.t() | nil,
          active_task: pid() | nil,
          active_task_ref: reference() | nil,
          draining: boolean(),
          heartbeat_ms: pos_integer(),
          poll_ms: non_neg_integer(),
          renew_ms: pos_integer(),
          poll_timeout_ms: non_neg_integer(),
          heartbeat_failures: non_neg_integer(),
          poll_failures: non_neg_integer()
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @spec snapshot(pid() | atom()) :: map()
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @spec drain(pid() | atom()) :: {:ok, map()} | {:error, term()}
  def drain(pid), do: GenServer.call(pid, :drain)

  @spec shutdown(pid() | atom(), timeout()) :: :ok | {:error, :shutdown_timeout | term()}
  def shutdown(pid, timeout \\ 30_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    with {:ok, _snapshot} <- drain(pid),
         :ok <- wait_until_drained(pid, deadline) do
      GenServer.call(pid, :shutdown, max(deadline - System.monotonic_time(:millisecond), 1))
    end
  end

  @impl GenServer
  def init(opts) do
    transport = Keyword.get(opts, :transport, DevIDE.Fleet.RemoteRunner.HttpTransport)

    with {:ok, transport_state} <- transport.init(opts),
         {:ok, transport_state} <- transport.register(transport_state) do
      state = %{
        transport: transport,
        transport_state: transport_state,
        runner_id: transport_state.runner_id,
        active_offer: nil,
        active_lease_id: nil,
        active_task: nil,
        active_task_ref: nil,
        draining: false,
        heartbeat_ms: Keyword.get(opts, :heartbeat_ms, @default_heartbeat_ms),
        poll_ms: Keyword.get(opts, :poll_ms, @default_poll_ms),
        renew_ms: Keyword.get(opts, :renew_ms, @default_renew_ms),
        poll_timeout_ms: Keyword.get(opts, :poll_timeout_ms, 0),
        heartbeat_failures: 0,
        poll_failures: 0,
        executor: Keyword.get(opts, :executor, Executor),
        executor_opts: Keyword.get(opts, :executor_opts, []),
        notify_pid: Keyword.get(opts, :notify_pid)
      }

      schedule(:heartbeat, state.heartbeat_ms)
      schedule(:poll, state.poll_ms)
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:snapshot, _from, state),
    do: {:reply, Map.drop(state, [:transport_state]), state}

  def handle_call(:drain, _from, state) do
    case state.transport.drain(state.transport_state) do
      {:ok, transport_state} ->
        Logger.info("runner draining: #{state.runner_id}")
        state = %{state | draining: true, transport_state: transport_state}
        {:reply, {:ok, public_snapshot(state)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:shutdown, _from, state) do
    case state.transport.shutdown(state.transport_state) do
      {:ok, transport_state} ->
        Logger.info("runner shutdown reported: #{state.runner_id}")
        {:stop, :normal, :ok, %{state | transport_state: transport_state}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info(:heartbeat, state) do
    state =
      case state.transport.heartbeat(state.transport_state) do
        {:ok, transport_state} ->
          %{state | transport_state: transport_state, heartbeat_failures: 0}

        {:error, reason} ->
          Logger.warning("runner heartbeat failed: #{inspect(reason)}")
          {ts, failures} = recover_or_backoff(state, reason, state.heartbeat_failures)
          %{state | transport_state: ts, heartbeat_failures: failures}
      end

    schedule(:heartbeat, backoff_ms(state.heartbeat_ms, state.heartbeat_failures))
    {:noreply, state}
  end

  def handle_info(:poll, %{draining: true, active_task: nil} = state) do
    schedule(:poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info(:poll, %{active_task: nil} = state) do
    state =
      case state.transport.poll_offer(state.transport_state, timeout_ms: state.poll_timeout_ms) do
        {:ok, offer} ->
          start_offer(%{state | poll_failures: 0}, offer)

        :none ->
          %{state | poll_failures: 0}

        {:error, reason} ->
          Logger.warning("runner poll failed: #{inspect(reason)}")
          {ts, failures} = recover_or_backoff(state, reason, state.poll_failures)
          %{state | transport_state: ts, poll_failures: failures}
      end

    schedule(:poll, backoff_ms(state.poll_ms, state.poll_failures))
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    schedule(:poll, state.poll_ms)
    {:noreply, state}
  end

  def handle_info(:renew_lease, %{active_lease_id: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:renew_lease, state) do
    expires_at = DateTime.add(DateTime.utc_now(), state.renew_ms * 4, :millisecond)

    message = %Messages.LeaseRenewed{
      lease_id: state.active_lease_id,
      expires_at: expires_at
    }

    _ = report_message(message, state)
    schedule(:renew_lease, state.renew_ms)
    {:noreply, state}
  end

  def handle_info({:runner_execution_finished, result}, state) do
    Logger.debug("runner execution finished: #{inspect(result)}")
    if state.notify_pid, do: send(state.notify_pid, {:remote_runner_finished, result})
    {:noreply, clear_active_execution(state)}
  end

  def handle_info({:runner_execution_failed, reason}, state) do
    Logger.warning("runner execution failed: #{inspect(reason)}")
    if state.notify_pid, do: send(state.notify_pid, {:remote_runner_failed, reason})
    {:noreply, clear_active_execution(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{active_task_ref: ref} = state) do
    Logger.warning("runner execution task exited: #{inspect(reason)}")
    if state.notify_pid, do: send(state.notify_pid, {:remote_runner_failed, reason})
    {:noreply, clear_active_execution(state)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp start_offer(state, offer) do
    parent = self()
    lease_id = lease_id(offer)

    report_fun = fn message -> report_message(message, %{state | active_lease_id: lease_id}) end

    {:ok, pid} =
      Task.start(fn ->
        case state.executor.run(offer, report_fun, state.executor_opts) do
          {:ok, result} -> send(parent, {:runner_execution_finished, result})
          {:error, reason} -> send(parent, {:runner_execution_failed, reason})
        end
      end)

    if lease_id, do: schedule(:renew_lease, state.renew_ms)

    %{
      state
      | active_offer: offer,
        active_lease_id: lease_id,
        active_task: pid,
        active_task_ref: Process.monitor(pid)
    }
  end

  defp clear_active_execution(state) do
    if state.active_task_ref do
      Process.demonitor(state.active_task_ref, [:flush])
    end

    %{
      state
      | active_offer: nil,
        active_lease_id: nil,
        active_task: nil,
        active_task_ref: nil
    }
  end

  defp report_message(message, state) do
    message
    |> Protocol.wrap(runner_id: state.runner_id, lease_id: state.active_lease_id)
    |> then(&state.transport.send_envelope(state.transport_state, &1))
  end

  defp lease_id(%{lease: %{id: id}}), do: id
  defp lease_id(%{"lease" => %{"id" => id}}), do: id
  defp lease_id(_offer), do: nil

  # A 404 from heartbeat/poll means the controller's in-memory registry forgot
  # this runner (e.g. after an instance restart). The GenServer preserves its
  # runner_id, so we re-register under the same id rather than 404-looping
  # forever. A 403 (runner_revoked) is intentionally NOT matched here — a
  # revoked runner must stay down.
  @spec recover_or_backoff(state(), term(), non_neg_integer()) ::
          {map(), non_neg_integer()}
  defp recover_or_backoff(state, reason, failures) do
    if runner_unknown?(reason) do
      case state.transport.register(state.transport_state) do
        {:ok, transport_state} ->
          Logger.info("runner re-registered after controller forgot it: #{state.runner_id}")
          {transport_state, 0}

        {:error, register_reason} ->
          if already_registered?(register_reason) do
            {state.transport_state, 0}
          else
            Logger.warning("runner re-register failed: #{inspect(register_reason)}")
            {state.transport_state, failures + 1}
          end
      end
    else
      {state.transport_state, failures + 1}
    end
  end

  defp runner_unknown?({:http_status, 404}), do: true
  defp runner_unknown?({:http_status, 404, _body}), do: true
  defp runner_unknown?(_reason), do: false

  defp already_registered?({:http_status, 409}), do: true
  defp already_registered?({:http_status, 409, _body}), do: true
  defp already_registered?(:already_registered), do: true
  defp already_registered?(_reason), do: false

  defp backoff_ms(base_ms, 0), do: base_ms

  defp backoff_ms(base_ms, failures) do
    min(base_ms * Integer.pow(2, failures), @max_backoff_ms)
  end

  defp schedule(message, timeout), do: Process.send_after(self(), message, timeout)

  defp public_snapshot(state), do: Map.drop(state, [:transport_state])

  defp wait_until_drained(pid, deadline) do
    try do
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :shutdown_timeout}
      else
        case snapshot(pid) do
          %{active_task: nil} ->
            :ok

          _snapshot ->
            Process.sleep(100)
            wait_until_drained(pid, deadline)
        end
      end
    catch
      :exit, {:noproc, _} -> :ok
    end
  end
end
