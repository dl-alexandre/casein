defmodule Casein.Agents.MCPTasksTest do
  @moduledoc """
  Registry behaviour for the MCP Tasks extension.

  Workers here block on a sentinel message rather than sleeping, so each test
  controls exactly when the background work reports.
  """

  use ExUnit.Case, async: false

  alias Casein.Agents.MCPTasks
  alias Casein.Test.Eventually

  @owner %{server: "Test", workspace_id: "ws-1", actor: "global", capability_id: nil}
  @other_owner %{server: "Test", workspace_id: "ws-2", actor: "global", capability_id: nil}

  # A worker that reports only once the test releases it.
  defp blocking_worker(test_pid) do
    fn task_id ->
      send(test_pid, {:worker_started, task_id, self()})

      receive do
        {:release, payload} -> payload
      end
    end
  end

  defp release(pid, payload), do: send(pid, {:release, payload})

  defp await_status(task_id, owner, status) do
    Eventually.await(
      fn ->
        case MCPTasks.get(task_id, owner) do
          {:ok, %{status: ^status} = task} -> task
          _ -> nil
        end
      end,
      message: "task #{task_id} never reached #{status}"
    )
  end

  test "a task is resolvable before its worker reports" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))

    assert_receive {:worker_started, ^task_id, worker}

    # The extension requires the task to exist before the response is sent.
    assert {:ok, task} = MCPTasks.get(task_id, @owner)
    assert task.status == "working"
    assert task.taskId == task_id
    assert task.ttlMs > 0
    assert task.pollIntervalMs > 0
    assert is_binary(task.createdAt)
    refute Map.has_key?(task, :result)

    release(worker, {:ok, %{content: [], structuredContent: %{"done" => true}}})

    assert %{result: %{structuredContent: %{"done" => true}}} =
             await_status(task_id, @owner, "completed")
  end

  test "a tool-level fault completes the task; a JSON-RPC error fails it" do
    {:ok, ok_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^ok_id, ok_worker}
    release(ok_worker, {:ok, %{isError: true, structuredContent: %{"error" => "nope"}}})

    # An application fault is a *completed* task carrying an error result.
    assert %{result: %{isError: true}} = await_status(ok_id, @owner, "completed")

    {:ok, err_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^err_id, err_worker}
    release(err_worker, {:error, %{code: -32_602, message: "Invalid params"}})

    assert %{error: %{code: -32_602}} = await_status(err_id, @owner, "failed")
  end

  test "a task is invisible to a different owner" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^task_id, worker}

    # Indistinguishable from "no such task", so ids cannot be probed.
    assert MCPTasks.get(task_id, @other_owner) == {:error, :unknown_task}
    assert MCPTasks.cancel(task_id, @other_owner) == {:error, :unknown_task}
    assert MCPTasks.update(task_id, @other_owner, %{}) == {:error, :unknown_task}

    # ...and it is still there for its real owner.
    assert {:ok, %{status: "working"}} = MCPTasks.get(task_id, @owner)

    release(worker, {:ok, %{}})
  end

  test "cancel is terminal and drops a late result from the worker" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^task_id, worker}

    assert MCPTasks.cancel(task_id, @owner) == :ok
    assert {:ok, %{status: "cancelled"}} = MCPTasks.get(task_id, @owner)
    assert MCPTasks.cancelled?(task_id)

    # The worker is terminated on cancel, but even a straggler that reports
    # afterwards must not move a terminal task.
    MCPTasks.complete(task_id, %{structuredContent: %{"late" => true}})
    assert {:ok, %{status: "cancelled"} = task} = MCPTasks.get(task_id, @owner)
    refute Map.has_key?(task, :result)

    refute Process.alive?(worker)
  end

  test "cancelling an already-completed task leaves it completed" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^task_id, worker}
    release(worker, {:ok, %{structuredContent: %{"done" => true}}})
    await_status(task_id, @owner, "completed")

    assert MCPTasks.cancel(task_id, @owner) == :ok
    assert {:ok, %{status: "completed"}} = MCPTasks.get(task_id, @owner)
  end

  test "a worker that dies without reporting fails its task" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^task_id, worker}

    Process.exit(worker, :kill)

    # Otherwise the task would sit at `working` until its TTL expired.
    assert %{error: %{message: message}} = await_status(task_id, @owner, "failed")
    assert message =~ "exited before reporting"
  end

  test "a worker returning an unexpected shape fails its task" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^task_id, worker}

    release(worker, :not_a_result_tuple)

    assert %{error: %{message: message}} = await_status(task_id, @owner, "failed")
    assert message =~ "unexpected shape"
  end

  test "the sweep reaps expired terminal tasks but spares live workers" do
    # Expired and terminal.
    {:ok, done_id} = MCPTasks.run(@owner, blocking_worker(self()), ttl_ms: 0)
    assert_receive {:worker_started, ^done_id, done_worker}
    release(done_worker, {:ok, %{}})
    await_status(done_id, @owner, "completed")

    # Expired but still working — must survive.
    {:ok, live_id} = MCPTasks.run(@owner, blocking_worker(self()), ttl_ms: 0)
    assert_receive {:worker_started, ^live_id, live_worker}

    assert MCPTasks.sweep_now() >= 1

    assert MCPTasks.get(done_id, @owner) == {:error, :unknown_task}
    assert {:ok, %{status: "working"}} = MCPTasks.get(live_id, @owner)

    release(live_worker, {:ok, %{}})
  end

  test "update accepts only outstanding input request keys" do
    {:ok, task_id} = MCPTasks.run(@owner, blocking_worker(self()))
    assert_receive {:worker_started, ^task_id, worker}

    # No producer of input_requests exists yet, so every key is unknown and the
    # call is an idempotent no-op rather than an error.
    assert MCPTasks.update(task_id, @owner, %{"confirm" => %{"action" => "accept"}}) == :ok
    assert {:ok, %{status: "working"}} = MCPTasks.get(task_id, @owner)

    release(worker, {:ok, %{}})
  end
end
