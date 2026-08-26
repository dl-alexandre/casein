defmodule Casein.Agents.JidoPod.Pod do
  @moduledoc """
  Workspace-keyed coordinator for headless Jido attempts.

  Owns admission, queueing, cancellation, and drain. Provider/action work
  runs in child workers so this mailbox stays short.
  """

  use GenServer, restart: :transient

  alias Casein.Agents.Activity
  alias Casein.Agents.JidoBudgets
  alias Casein.Agents.JidoLifecycle
  alias Casein.Agents.JidoPod.{Attempt, Fleet, Metrics, Worker}
  alias Phoenix.PubSub

  @topic_prefix "jido_pod:"

  def child_spec(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    %{
      id: {__MODULE__, workspace_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  def start_link(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    GenServer.start_link(__MODULE__, opts, name: via(workspace_id))
  end

  def via(workspace_id) when is_binary(workspace_id) do
    {:via, Registry, {Casein.Agents.JidoPod.Registry, {:pod, workspace_id}}}
  end

  def whereis(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(Casein.Agents.JidoPod.Registry, {:pod, workspace_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  def admit(pid, attrs), do: GenServer.call(pid, {:admit, attrs})
  def cancel(pid, attempt_id), do: GenServer.call(pid, {:cancel, attempt_id})
  def resume(pid, attempt_id), do: GenServer.call(pid, {:resume, attempt_id})
  def status(pid, attempt_id), do: GenServer.call(pid, {:status, attempt_id})
  def list(pid), do: GenServer.call(pid, :list)
  def drain(pid), do: GenServer.call(pid, :drain)
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def subscribe(workspace_id) when is_binary(workspace_id) do
    PubSub.subscribe(Casein.PubSub, topic(workspace_id))
  end

  @impl true
  def init(opts) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)

    {:ok,
     %{
       workspace_id: workspace_id,
       attempts: %{},
       queue: :queue.new(),
       draining?: false
     }}
  end

  @impl true
  def handle_call({:admit, _attrs}, _from, %{draining?: true} = state) do
    Metrics.inc(:rejected)
    {:reply, {:error, :draining}, state}
  end

  def handle_call({:admit, attrs}, _from, state) do
    started_at = System.monotonic_time(:millisecond)
    attempt = build_attempt(state.workspace_id, attrs)
    state = put_attempt(state, attempt)
    Metrics.inc(:admitted)
    publish(attempt)

    case JidoBudgets.precheck_from(state.workspace_id, pod_usage(state)) do
      {:reject, reason} ->
        state = maybe_pressure_drain(state, reason)
        reject_admit(state, attempt, reason, started_at)

      {:queue, reason} ->
        JidoBudgets.record_admission(System.monotonic_time(:millisecond) - started_at)
        queue_or_reject(state, attempt, reason)

      :ok ->
        JidoBudgets.record_admission(System.monotonic_time(:millisecond) - started_at)

        cond do
          can_start?(state) ->
            case start_attempt(state, attempt.id) do
              {:ok, state, started} ->
                JidoBudgets.record(state.workspace_id, :admit, :ok, %{
                  running: running_count(state)
                })

                {:reply, {:ok, Attempt.public(started)}, state}

              {:error, state, reason} ->
                queue_or_reject(state, attempt, reason)
            end

          queue_len(state) < max_queued() ->
            {state, queued} = enqueue(state, attempt.id)
            {:reply, {:ok, Attempt.public(queued)}, state}

          true ->
            reject_admit(state, attempt, :queue_full, started_at)
        end
    end
  end

  def handle_call({:cancel, attempt_id}, _from, state) do
    case Map.get(state.attempts, attempt_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{state: current} = attempt ->
        if Attempt.terminal?(current) do
          {:reply, {:error, :already_terminal}, state}
        else
          {state, cancelled} = cancel_attempt(state, attempt)
          {:reply, {:ok, Attempt.public(cancelled)}, state}
        end
    end
  end

  def handle_call({:resume, attempt_id}, _from, state) do
    case Map.get(state.attempts, attempt_id) do
      %Attempt{state: :awaiting_human} = attempt ->
        case start_attempt(state, attempt.id) do
          {:ok, state, started} -> {:reply, {:ok, Attempt.public(started)}, state}
          {:error, state, reason} -> {:reply, {:error, reason}, state}
        end

      %Attempt{} ->
        {:reply, {:error, :not_awaiting_human}, state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:status, attempt_id}, _from, state) do
    case Map.get(state.attempts, attempt_id) do
      nil -> {:reply, {:error, :not_found}, state}
      attempt -> {:reply, {:ok, Attempt.public(attempt)}, state}
    end
  end

  def handle_call(:list, _from, state) do
    attempts =
      state.attempts
      |> Map.values()
      |> Enum.sort_by(& &1.inserted_at, {:asc, DateTime})
      |> Enum.map(&Attempt.public/1)

    {:reply, attempts, state}
  end

  def handle_call(:drain, _from, state) do
    state = %{state | draining?: true, queue: :queue.new()}

    {state, cancelled} =
      Enum.reduce(queued_ids(state.attempts), {state, []}, fn id, {acc, list} ->
        case Map.get(acc.attempts, id) do
          %Attempt{state: :queued} = attempt ->
            {acc, done} = finish(acc, attempt, :cancelled, reason: :drain)
            {acc, [done | list]}

          _ ->
            {acc, list}
        end
      end)

    {:reply, {:ok, Enum.map(cancelled, &Attempt.public/1)}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, pod_snapshot(state), state}
  end

  @impl true
  def handle_call({:progress, attempt_id, next_index, completed}, _from, state) do
    case Map.get(state.attempts, attempt_id) do
      %Attempt{} = attempt ->
        updated =
          Attempt.transition(attempt, attempt.state,
            next_index: next_index,
            completed: completed
          )

        publish(updated)
        {:reply, :ok, put_attempt(state, updated)}

      nil ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info(:jido_fleet_available, state) do
    {:noreply, pump(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case find_by_worker(state, ref, pid) do
      nil ->
        {:noreply, state}

      attempt ->
        {:noreply, settle_worker(state, attempt, reason)}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.attempts, fn {_id, attempt} ->
      if attempt.lease?, do: Fleet.release(state.workspace_id)
      JidoBudgets.release_provider(attempt.id)
      JidoBudgets.release_lease(attempt.id)
      JidoBudgets.release_memory(attempt.id)

      if is_pid(attempt.worker_pid) and Process.alive?(attempt.worker_pid) do
        Worker.cancel(attempt.worker_pid)
      end
    end)

    :ok
  end

  defp build_attempt(workspace_id, attrs) do
    Attempt.new(%{
      id: Map.get(attrs, :attempt_id) || Ecto.UUID.generate(),
      workspace_id: workspace_id,
      task_id: Map.get(attrs, :task_id) || Ecto.UUID.generate(),
      worktree_path: Map.get(attrs, :worktree_path),
      principal: Map.get(attrs, :principal),
      actions: normalize_actions(Map.get(attrs, :actions, [])),
      deadline_ms: Map.get(attrs, :deadline_ms, config(:default_attempt_deadline_ms, 60_000)),
      action_timeout_ms:
        Map.get(attrs, :action_timeout_ms, config(:default_action_timeout_ms, 5_000)),
      max_retries: Map.get(attrs, :max_retries, config(:max_retries, 1))
    })
  end

  defp normalize_actions(actions) when is_list(actions) do
    Enum.map(actions, fn
      %{name: name} = action ->
        %{
          name: name,
          args: Map.get(action, :args, %{}),
          mutation_token: Map.get(action, :mutation_token)
        }

      {name, args} when is_binary(name) ->
        %{name: name, args: args || %{}}

      name when is_binary(name) ->
        %{name: name, args: %{}}
    end)
  end

  defp queue_or_reject(state, attempt, reason) do
    if queue_len(state) < max_queued() do
      {state, queued} = enqueue(state, attempt.id, reason)
      {:reply, {:ok, Attempt.public(queued)}, state}
    else
      reject_admit(state, attempt, reject_reason(reason), 0)
    end
  end

  defp reject_admit(state, attempt, reason, started_at) do
    if started_at > 0 do
      JidoBudgets.record_admission(System.monotonic_time(:millisecond) - started_at)
    end

    state = drop_attempt(state, attempt.id)
    Metrics.inc(:rejected)
    Metrics.emit(:admit, %{queue_depth: queue_len(state)}, %{result: :rejected, reason: reason})
    JidoBudgets.record(state.workspace_id, :reject, reason, %{queue_depth: queue_len(state)})
    {:reply, {:error, reject_error(reason)}, state}
  end

  defp reject_reason(:workspace_limit), do: :queue_full
  defp reject_reason(reason), do: reason

  defp reject_error(:queue_full), do: :backpressure
  defp reject_error(reason), do: reason

  defp maybe_pressure_drain(state, reason) when reason in [:cpu_pressure, :rss_pressure] do
    {state, cancelled} =
      Enum.reduce(queued_ids(state.attempts), {%{state | queue: :queue.new()}, []}, fn id,
                                                                                       {acc, list} ->
        case Map.get(acc.attempts, id) do
          %Attempt{state: :queued} = attempt ->
            {acc, done} = finish(acc, attempt, :cancelled, reason: reason)
            {acc, [done | list]}

          _ ->
            {acc, list}
        end
      end)

    JidoBudgets.record(state.workspace_id, :drain, reason, %{drained: length(cancelled)})
    state
  end

  defp maybe_pressure_drain(state, _reason), do: state

  defp pod_usage(state) do
    %{
      running: running_count(state),
      queued: queue_len(state),
      draining?: state.draining?
    }
  end

  defp enqueue(state, attempt_id, reason \\ :workspace_limit) do
    attempt = Map.fetch!(state.attempts, attempt_id)
    queued = Attempt.transition(attempt, :queued, reason: reason)
    Fleet.register_waiter(state.workspace_id)
    Metrics.inc(:queued)
    Metrics.emit(:admit, %{queue_depth: queue_len(state) + 1}, %{result: :queued, reason: reason})
    JidoBudgets.record(state.workspace_id, :queue, reason, %{queue_depth: queue_len(state) + 1})
    publish(queued)

    {%{
       state
       | attempts: Map.put(state.attempts, attempt_id, queued),
         queue: :queue.in(attempt_id, state.queue)
     }, queued}
  end

  defp start_attempt(state, attempt_id) do
    attempt = Map.fetch!(state.attempts, attempt_id)

    cond do
      not attempt.lease? and running_count(state) >= max_running() ->
        {:error, state, :workspace_limit}

      attempt.lease? ->
        acquire_provider_and_spawn(state, attempt, false)

      true ->
        case Fleet.try_acquire(state.workspace_id) do
          :ok ->
            acquire_provider_and_spawn(state, attempt, true)

          {:error, reason} when reason in [:fleet_limit, :fairness, :workspace_share] ->
            Fleet.register_waiter(state.workspace_id)
            {:error, state, reason}
        end
    end
  end

  defp acquire_provider_and_spawn(state, attempt, acquired_now?) do
    case JidoBudgets.try_provider(attempt.id) do
      :ok ->
        spawn_worker(state, attempt, acquired_now?)

      {:error, :provider_limit} ->
        if acquired_now?, do: Fleet.release(state.workspace_id)
        Fleet.register_waiter(state.workspace_id)
        {:error, state, :provider_limit}
    end
  end

  defp spawn_worker(state, attempt, acquired_now?) do
    opts = [attempt: %{attempt | worker_pid: nil, worker_ref: nil}, pod: self()]

    case DynamicSupervisor.start_child(Casein.Agents.JidoPod.WorkerSupervisor, {Worker, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        Worker.start_run(pid)

        started =
          Attempt.transition(attempt, :running,
            worker_pid: pid,
            worker_ref: ref,
            lease?: true,
            reason: nil
          )

        JidoBudgets.acquire_lease(state.workspace_id, started.id)
        Metrics.inc(:running)
        Metrics.emit(:admit, %{running: running_count(state) + 1}, %{result: :running})
        publish(started)
        {:ok, put_attempt(state, started), started}

      {:error, reason} ->
        JidoBudgets.release_provider(attempt.id)
        if acquired_now?, do: Fleet.release(state.workspace_id)
        {:error, state, reason}
    end
  end

  defp cancel_attempt(state, %Attempt{state: :queued} = attempt) do
    state = %{state | queue: drop_queue(state.queue, attempt.id)}
    finish(state, attempt, :cancelled, reason: :cancelled)
  end

  defp cancel_attempt(state, %Attempt{} = attempt) do
    if is_pid(attempt.worker_pid) and Process.alive?(attempt.worker_pid) do
      Worker.cancel(attempt.worker_pid)
    end

    marked = Attempt.transition(attempt, attempt.state, cancel_requested?: true)
    {put_attempt(state, marked), marked}
  end

  defp settle_worker(state, attempt, reason) do
    {next_state, opts} = outcome(attempt, reason)

    cond do
      match?({:shutdown, {:completed, _}}, reason) ->
        {next_state, opts} = outcome(attempt, reason)
        {state, _done} = finish(state, attempt, next_state, opts)
        pump(state)

      attempt.cancel_requested? ->
        {state, _done} = finish(state, attempt, :cancelled, reason: :cancelled)
        pump(state)

      next_state == :retrying ->
        retry(state, attempt, opts)

      next_state == :awaiting_human ->
        kept =
          Attempt.transition(
            attempt,
            :awaiting_human,
            Keyword.merge(opts, worker_pid: nil, worker_ref: nil, lease?: true)
          )

        JidoBudgets.release_provider(attempt.id)
        Metrics.inc(:awaiting_human)
        publish(kept)
        put_attempt(state, kept)

      true ->
        {state, _done} = finish(state, attempt, next_state, opts)
        pump(state)
    end
  end

  defp outcome(_attempt, {:shutdown, :cancelled}), do: {:cancelled, [reason: :cancelled]}

  defp outcome(attempt, {:shutdown, {:completed, result}}) do
    completed = Map.get(result, :completed, attempt.completed)
    {:completed, [result: result, completed: completed, next_index: length(completed)]}
  end

  defp outcome(_attempt, {:shutdown, {:failed, {:action_crashed, _} = error}}),
    do: {:retrying, [error: error, reason: :worker_crash]}

  defp outcome(_attempt, {:shutdown, {:failed, error}}),
    do: {:failed, [error: error, reason: :failed]}

  defp outcome(_attempt, {:shutdown, {:timed_out, error}}),
    do: {:timed_out, [error: error, reason: :timed_out]}

  defp outcome(_attempt, {:shutdown, {:provider_unavailable, error}}),
    do: {:provider_unavailable, [error: error, reason: :provider_unavailable]}

  defp outcome(_attempt, {:shutdown, {:awaiting_human, payload}}),
    do: {:awaiting_human, [result: payload, reason: :awaiting_human]}

  defp outcome(_attempt, {:shutdown, {:retryable, error}}),
    do: {:retrying, [error: error, reason: :retryable]}

  defp outcome(_attempt, :killed), do: {:retrying, [error: :killed, reason: :worker_crash]}
  defp outcome(_attempt, {:shutdown, _}), do: {:failed, [error: :shutdown, reason: :failed]}
  defp outcome(_attempt, reason), do: {:retrying, [error: reason, reason: :worker_crash]}

  defp retry(state, attempt, opts) do
    if attempt.retries < attempt.max_retries do
      retried =
        Attempt.transition(
          attempt,
          :retrying,
          Keyword.merge(opts,
            retries: attempt.retries + 1,
            worker_pid: nil,
            worker_ref: nil,
            lease?: false
          )
        )

      if attempt.lease?, do: Fleet.release(state.workspace_id)
      JidoBudgets.release_provider(attempt.id)
      JidoBudgets.release_lease(attempt.id)
      Metrics.inc(:retrying)

      if opts[:reason] == :worker_crash do
        Metrics.inc(:worker_crash)
        JidoBudgets.crash(state.workspace_id)
      end

      publish(retried)
      state = put_attempt(state, retried)

      case start_attempt(state, retried.id) do
        {:ok, state, _started} ->
          state

        {:error, state, reason} ->
          {state, _queued} = enqueue(state, retried.id, reason)
          state
      end
    else
      if opts[:reason] == :worker_crash do
        Metrics.inc(:worker_crash)
        JidoBudgets.crash(state.workspace_id)
      end

      {state, _done} =
        finish(state, attempt, :failed, Keyword.put(opts, :reason, :retries_exhausted))

      pump(state)
    end
  end

  defp finish(state, attempt, next_state, opts) do
    if attempt.lease?, do: Fleet.release(state.workspace_id)
    JidoBudgets.release_provider(attempt.id)
    JidoBudgets.release_lease(attempt.id)
    JidoBudgets.release_memory(attempt.id)

    done =
      Attempt.transition(
        attempt,
        next_state,
        Keyword.merge(opts, worker_pid: nil, worker_ref: nil, lease?: false)
      )

    Metrics.inc(next_state)
    publish(done)
    emit_stop(done)
    {put_attempt(state, done), done}
  end

  defp pump(%{draining?: true} = state), do: state

  defp pump(state) do
    if can_start?(state) do
      dequeue_and_start(state)
    else
      if queue_len(state) > 0, do: Fleet.register_waiter(state.workspace_id)
      state
    end
  end

  defp dequeue_and_start(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, attempt_id}, queue} ->
        start_dequeued(%{state | queue: queue}, attempt_id)
    end
  end

  defp start_dequeued(state, attempt_id) do
    case Map.get(state.attempts, attempt_id) do
      %Attempt{state: current} = attempt when current in [:queued, :retrying, :admitted] ->
        start_or_requeue(state, attempt)

      _ ->
        pump(state)
    end
  end

  defp start_or_requeue(state, attempt) do
    case start_attempt(state, attempt.id) do
      {:ok, state, _started} ->
        pump(state)

      {:error, state, reason} ->
        {state, _queued} = enqueue(state, attempt.id, reason)
        state
    end
  end

  defp can_start?(state), do: running_count(state) < max_running()

  defp running_count(state) do
    state.attempts
    |> Map.values()
    |> Enum.count(& &1.lease?)
  end

  defp queue_len(state), do: :queue.len(state.queue)

  defp queued_ids(attempts) do
    attempts
    |> Map.values()
    |> Enum.filter(&(&1.state == :queued))
    |> Enum.map(& &1.id)
  end

  defp find_by_worker(state, ref, pid) do
    Enum.find_value(state.attempts, fn
      {_id, %Attempt{worker_ref: ^ref} = attempt} -> attempt
      {_id, %Attempt{worker_pid: ^pid} = attempt} -> attempt
      _ -> nil
    end)
  end

  defp put_attempt(state, attempt) do
    %{state | attempts: Map.put(state.attempts, attempt.id, attempt)}
  end

  defp drop_attempt(state, attempt_id) do
    %{
      state
      | attempts: Map.delete(state.attempts, attempt_id),
        queue: drop_queue(state.queue, attempt_id)
    }
  end

  defp drop_queue(queue, attempt_id) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == attempt_id))
    |> :queue.from_list()
  end

  defp publish(%Attempt{} = attempt) do
    public_attempt = Attempt.public(attempt)

    _ =
      Activity.record(%{
        workspace_id: attempt.workspace_id,
        source: :jido_pod,
        tool: "jido_pod",
        summary: "attempt #{attempt.id} #{attempt.state}",
        metadata: %{
          task_id: attempt.task_id,
          attempt_id: attempt.id,
          worktree_path: attempt.worktree_path,
          state: attempt.state,
          reason: public_attempt.reason,
          headless: true
        },
        status:
          if(attempt.state in [:failed, :timed_out, :provider_unavailable], do: :error, else: :ok)
      })

    PubSub.broadcast(
      Casein.PubSub,
      topic(attempt.workspace_id),
      {:jido_attempt, public_attempt}
    )

    _ = JidoLifecycle.ingest_attempt(public_attempt)
    :ok
  end

  defp emit_stop(attempt) do
    duration =
      case {attempt.started_at, attempt.finished_at} do
        {%DateTime{} = start, %DateTime{} = finish} -> DateTime.diff(finish, start, :millisecond)
        _ -> 0
      end

    Metrics.emit(:attempt_stop, %{duration: duration}, %{
      workspace_id: attempt.workspace_id,
      state: attempt.state
    })
  end

  defp pod_snapshot(state) do
    %{
      workspace_id: state.workspace_id,
      running: running_count(state),
      queued: queue_len(state),
      draining?: state.draining?,
      attempts: map_size(state.attempts),
      max_running: max_running(),
      max_queued: max_queued()
    }
  end

  defp max_running, do: config(:max_running_per_workspace, 2)
  defp max_queued, do: config(:max_queued_per_workspace, 4)

  defp config(key, default) do
    Application.get_env(:casein, :jido_pod, []) |> Keyword.get(key, default)
  end

  defp topic(workspace_id), do: @topic_prefix <> workspace_id
end
