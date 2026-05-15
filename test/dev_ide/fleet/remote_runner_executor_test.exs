defmodule DevIDE.Fleet.RemoteRunnerExecutorTest do
  use ExUnit.Case, async: false

  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.RemoteRunner.Executor

  setup do
    previous_adapter = Application.get_env(:dev_ide, :commands_adapter)
    previous_test_pid = Application.get_env(:dev_ide, :fake_command_test_pid)

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)
    Application.put_env(:dev_ide, :fake_command_test_pid, self())

    on_exit(fn ->
      if previous_adapter do
        Application.put_env(:dev_ide, :commands_adapter, previous_adapter)
      else
        Application.delete_env(:dev_ide, :commands_adapter)
      end

      if previous_test_pid do
        Application.put_env(:dev_ide, :fake_command_test_pid, previous_test_pid)
      else
        Application.delete_env(:dev_ide, :fake_command_test_pid)
      end
    end)

    :ok
  end

  @tag :tmp_dir
  test "executes from offered worktree path without local workspace state", %{tmp_dir: tmp_dir} do
    offer = offered_assignment(tmp_dir)
    test_pid = self()

    assert {:ok, %{status: :completed, exit_code: 0}} =
             Executor.run(offer, fn message ->
               send(test_pid, {:reported, message})
               {:ok, :sent}
             end)

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]}
    assert_receive {:reported, %Messages.ExecutionStarted{}}
    assert_receive {:reported, %Messages.OutputChunk{chunk: "ok\n", seq: 1, stream: "stdout"}}
    assert_receive {:reported, %Messages.ExecutionCompleted{}}
  end

  @tag :tmp_dir
  test "emits ExecutionFailed when report_fun fails on OutputChunk", %{tmp_dir: tmp_dir} do
    # Track B: a transport error during chunk delivery must never silently
    # abandon the execution. The executor should make a best-effort attempt
    # to ship ExecutionFailed before exiting, so the controller has a
    # protocol record of what happened.
    offer = offered_assignment(tmp_dir)
    test_pid = self()

    report_fun = fn
      %Messages.ExecutionStarted{} = msg ->
        send(test_pid, {:reported, msg})
        {:ok, :sent}

      %Messages.OutputChunk{} = msg ->
        send(test_pid, {:reported, msg})
        {:error, :transport_down}

      %Messages.ExecutionFailed{} = msg ->
        send(test_pid, {:reported, msg})
        {:ok, :sent}

      msg ->
        send(test_pid, {:reported, msg})
        {:ok, :sent}
    end

    assert {:error, {:report_failed, :transport_down}} = Executor.run(offer, report_fun)

    assert_receive {:reported, %Messages.ExecutionStarted{}}
    assert_receive {:reported, %Messages.OutputChunk{}}

    assert_receive {:reported,
                    %Messages.ExecutionFailed{
                      reason: "report_failed: " <> _,
                      evidence: %{failure_class: "report_failed"}
                    }}
  end

  @tag :tmp_dir
  test "does not loop when ExecutionFailed itself fails to ship", %{tmp_dir: tmp_dir} do
    # If the transport is so broken that the ExecutionFailed report also
    # errors, the executor must give up rather than loop. We assert by
    # counting: at most one ExecutionFailed reaches report_fun.
    offer = offered_assignment(tmp_dir)
    test_pid = self()

    report_fun = fn
      %Messages.ExecutionStarted{} = msg ->
        send(test_pid, {:reported, msg})
        {:ok, :sent}

      %Messages.OutputChunk{} = msg ->
        send(test_pid, {:reported, msg})
        {:error, :transport_down}

      %Messages.ExecutionFailed{} = msg ->
        send(test_pid, {:reported, msg})
        {:error, :transport_still_down}

      msg ->
        send(test_pid, {:reported, msg})
        {:ok, :sent}
    end

    assert {:error, {:report_failed, :transport_down}} = Executor.run(offer, report_fun)

    # Drain reports — there should be exactly one ExecutionFailed.
    assert_receive {:reported, %Messages.ExecutionFailed{}}
    refute_receive {:reported, %Messages.ExecutionFailed{}}, 100
  end

  defp offered_assignment(worktree_path) do
    message = %Messages.AssignmentOffered{
      assignment_id: Ecto.UUID.generate(),
      safe_action_id: "command:format",
      workspace_id: "remote-workspace",
      worktree_path: worktree_path,
      lease_duration_ms: 30_000
    }

    envelope =
      Protocol.wrap(message,
        runner_id: Ecto.UUID.generate(),
        lease_id: Ecto.UUID.generate()
      )

    %{envelope: Protocol.serialize(envelope)}
  end
end
