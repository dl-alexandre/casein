defmodule Casein.Agents.JidoPod.Worker do
  @moduledoc """
  Short-lived attempt worker. Runs typed Code actions only; never tmux or a shell.
  """

  use GenServer, restart: :temporary

  alias Casein.Agents.JidoBudgets
  alias Casein.Agents.JidoPod.{Attempt, CodeActions}

  def child_spec(opts) do
    attempt = Keyword.fetch!(opts, :attempt)

    %{
      id: {__MODULE__, attempt.workspace_id, attempt.id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    pod = Keyword.get(opts, :pod, self())

    GenServer.start_link(__MODULE__, Keyword.put(opts, :pod, pod),
      name:
        {:via, Registry,
         {Casein.Agents.JidoPod.Registry, {:worker, attempt.workspace_id, attempt.id}}}
    )
  end

  def cancel(pid) when is_pid(pid), do: GenServer.cast(pid, :cancel)

  def start_run(pid) when is_pid(pid), do: send(pid, :run)

  @impl true
  def init(opts) do
    attempt = Keyword.fetch!(opts, :attempt)
    timer = Process.send_after(self(), :deadline, max(attempt.deadline_ms, 1))

    {:ok,
     %{
       attempt: attempt,
       pod: Keyword.fetch!(opts, :pod),
       task: nil,
       action_timer: nil,
       deadline_timer: timer
     }}
  end

  @impl true
  def handle_cast(:cancel, state) do
    stop_action(state)
    {:stop, {:shutdown, :cancelled}, state}
  end

  @impl true
  def handle_info(:run, state), do: run_next(state)

  def handle_info(:deadline, state) do
    stop_action(state)
    {:stop, {:shutdown, {:timed_out, :deadline}}, state}
  end

  def handle_info(:action_timeout, %{task: %Task{} = task} = state) do
    _ = Task.shutdown(task, :brutal_kill)

    {:stop, {:shutdown, {:retryable, %{error: :timeout}}},
     %{state | task: nil, action_timer: nil}}
  end

  def handle_info(:action_timeout, state), do: {:noreply, state}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    cancel_timer(state.action_timer)
    handle_action_result(%{state | task: nil, action_timer: nil}, result)
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    cancel_timer(state.action_timer)

    {:stop, {:shutdown, {:failed, {:action_crashed, reason}}},
     %{state | task: nil, action_timer: nil}}
  end

  defp run_next(state) do
    case Attempt.remaining_actions(state.attempt) do
      [] ->
        {:stop, {:shutdown, {:completed, %{completed: state.attempt.completed}}}, state}

      [action | _rest] ->
        case JidoBudgets.charge_memory(state.attempt.workspace_id, state.attempt.id, action) do
          :ok ->
            start_action(state, action)

          {:error, :memory_limit} ->
            {:stop, {:shutdown, {:failed, :memory_limit}}, state}
        end
    end
  end

  defp start_action(state, action) do
    name = Map.fetch!(action, :name)
    args = Map.get(action, :args, %{})
    attempt = state.attempt

    context = %{
      workspace_id: attempt.workspace_id,
      task_id: attempt.task_id,
      attempt_id: attempt.id,
      worktree_path: attempt.worktree_path,
      principal: attempt.principal,
      actor: attempt.principal
    }

    task =
      Task.Supervisor.async_nolink(Casein.Agents.MCPTaskSupervisor, fn ->
        {name, action, CodeActions.invoke(name, args, context)}
      end)

    timer = Process.send_after(self(), :action_timeout, max(attempt.action_timeout_ms, 1))
    {:noreply, %{state | task: task, action_timer: timer}}
  end

  defp handle_action_result(state, {name, action, result}) do
    case classify(result) do
      {:ok, value} ->
        case JidoBudgets.charge_memory(state.attempt.workspace_id, state.attempt.id, value) do
          :ok ->
            attempt = record_completed(state.attempt, name, action, value)

            GenServer.call(
              state.pod,
              {:progress, attempt.id, attempt.next_index, attempt.completed}
            )

            run_next(%{state | attempt: attempt})

          {:error, :memory_limit} ->
            {:stop, {:shutdown, {:failed, :memory_limit}}, state}
        end

      {:awaiting_human, value} ->
        {:stop,
         {:shutdown, {:awaiting_human, %{result: value, next_index: state.attempt.next_index}}},
         state}

      {:provider_unavailable, error} ->
        {:stop, {:shutdown, {:provider_unavailable, error}}, state}

      {:retryable, error} ->
        {:stop, {:shutdown, {:retryable, error}}, state}

      {:error, error} ->
        {:stop, {:shutdown, {:failed, error}}, state}
    end
  end

  defp record_completed(attempt, name, action, value) do
    completed = %{
      index: attempt.next_index,
      name: name,
      mutation_token: Map.get(action, :mutation_token),
      result: value
    }

    %{attempt | next_index: attempt.next_index + 1, completed: attempt.completed ++ [completed]}
  end

  defp classify({:ok, %{status: :awaiting_human} = value}), do: {:awaiting_human, value}
  defp classify({:ok, %{awaiting_human: true} = value}), do: {:awaiting_human, value}

  defp classify({:ok, %{status: status} = value}) when status in ["failed", "error"],
    do: {:error, value}

  defp classify({:ok, value}), do: {:ok, value}
  defp classify({:awaiting_human, value}), do: {:awaiting_human, value}
  defp classify({:error, :awaiting_human}), do: {:awaiting_human, :awaiting_human}

  defp classify({:error, :provider_unavailable}),
    do: {:provider_unavailable, :provider_unavailable}

  defp classify({:error, :timeout}), do: {:retryable, :timeout}
  defp classify({:error, %{error: :awaiting_human} = error}), do: {:awaiting_human, error}

  defp classify({:error, %{error: :provider_unavailable} = error}),
    do: {:provider_unavailable, error}

  defp classify({:error, %{error: :timeout} = error}), do: {:retryable, error}
  defp classify({:error, %{retryable: true} = error}), do: {:retryable, error}
  defp classify({:error, error}), do: {:error, error}
  defp classify(other), do: {:error, other}

  defp stop_action(%{task: %Task{} = task, action_timer: timer}) do
    cancel_timer(timer)
    _ = Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp stop_action(%{action_timer: timer}) do
    cancel_timer(timer)
    :ok
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)
end
