defmodule DevIDE.Fleet.RemoteFailureModesTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages

  setup do
    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    ArtifactStore.clear()
    ExecutionProjectionStore.clear()
    OutputStream.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      ArtifactStore.clear()
      ExecutionProjectionStore.clear()
      OutputStream.clear()
    end)

    :ok
  end

  test "runner disconnect mid-execution leaves durable state for attach and does not complete assignment" do
    %{assignment: assignment, runner: runner, lease: lease, execution_id: execution_id} =
      start_execution()

    send_output(assignment.id, runner.id, lease.id, execution_id, "before disconnect\n")

    :ok = Fleet.mark_offline([runner.id])

    assert {:ok, running} = Assignments.get(assignment.id)
    assert running.state == "running"
    assert {:ok, active_lease} = Fleet.get_lease(assignment.id)
    assert active_lease.id == lease.id

    assert {:ok, packet} = Fleet.attach_packet(execution_id)
    assert [%{data: "before disconnect\n"}] = packet.historical_chunks
  end

  test "stale lease renewal is rejected" do
    {:ok, runner} = Fleet.register(%{hostname: "stale-renewal"})
    {:ok, lease} = Fleet.acquire_lease(runner.id, "assignment-stale", duration_ms: -1)

    renewal = %Messages.LeaseRenewed{
      lease_id: lease.id,
      expires_at: DateTime.add(DateTime.utc_now(), 60_000, :millisecond)
    }

    envelope = Protocol.wrap(renewal, runner_id: runner.id, lease_id: lease.id)
    assert {:error, :lease_expired_or_inactive} = Protocol.send_to_controller(envelope)
  end

  test "revoked runner cannot heartbeat or poll for work" do
    runner_id = Ecto.UUID.generate()
    {:ok, runner} = Fleet.register(%{id: runner_id, hostname: "revoked-runner"})
    {:ok, _identity} = Fleet.set_runner_trust_state(runner.id, :revoked)

    assert {:error, :runner_revoked} = Fleet.heartbeat(runner.id)
    assert {:error, :runner_revoked} = Fleet.poll_transport_offer(runner.id, timeout_ms: 0)

    assert {:error, :runner_revoked} =
             Fleet.register(%{id: runner_id, hostname: "revoked-runner"})
  end

  test "duplicate completion is rejected after the first terminal transition" do
    %{assignment: assignment, runner: runner, lease: lease, execution_id: execution_id} =
      start_execution()

    completed = %Messages.ExecutionCompleted{
      assignment_id: assignment.id,
      execution_id: execution_id,
      completed_at: DateTime.utc_now(),
      evidence: %{exit_code: 0}
    }

    envelope = Protocol.wrap(completed, runner_id: runner.id, lease_id: lease.id)
    assert {:ok, terminal} = Protocol.send_to_controller(envelope)
    assert terminal.state == "completed"

    assert {:error, reason} = Protocol.send_to_controller(envelope)
    assert reason in [:lease_expired_or_inactive, :lease_not_found]
  end

  test "artifact upload after lease expiry is rejected and leaves no artifact chunk" do
    {:ok, runner} = Fleet.register(%{hostname: "artifact-expiry"})
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-artifact"})
    {:ok, _claimed} = Assignments.claim(assignment.id, runner.id)
    {:ok, lease} = Fleet.acquire_lease(runner.id, assignment.id, duration_ms: -1)
    execution_id = Ecto.UUID.generate()

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: execution_id,
        assignment_id: assignment.id,
        runner_id: runner.id,
        lease_id: lease.id,
        state: :started,
        started_at: DateTime.utc_now()
      })

    artifact = %Messages.ArtifactChunk{
      assignment_id: assignment.id,
      execution_id: execution_id,
      artifact_id: "logs",
      chunk: "late artifact",
      position: 0,
      timestamp: DateTime.utc_now()
    }

    envelope = Protocol.wrap(artifact, runner_id: runner.id, lease_id: lease.id)
    assert {:error, :lease_expired_or_inactive} = Protocol.send_to_controller(envelope)
    assert ArtifactStore.chunks(execution_id) == []
  end

  test "runner transport rejects controller-origin instructions and unsafe command offers" do
    {:ok, runner} = Fleet.register(%{hostname: "spoofed-offer"})
    {:ok, lease} = Fleet.acquire_lease(runner.id, "assignment-spoof")

    spoofed = %Messages.AssignmentOffered{
      assignment_id: "assignment-spoof",
      safe_action_id: "command:rm_rf",
      workspace_id: "ws-spoof"
    }

    envelope = Protocol.wrap(spoofed, runner_id: runner.id, lease_id: lease.id)

    assert {:error, :runner_cannot_send_controller_instruction} =
             Protocol.send_to_controller(envelope)
  end

  test "runner output is redacted before durable storage and live streaming" do
    %{assignment: assignment, runner: runner, lease: lease, execution_id: execution_id} =
      start_execution()

    send_output(
      assignment.id,
      runner.id,
      lease.id,
      execution_id,
      "TOKEN=super-secret Bearer abc.def.ghi\n"
    )

    assert [%{data: data}] = ArtifactStore.chunks(execution_id)
    assert data =~ "TOKEN=[REDACTED]"
    assert data =~ "Bearer [REDACTED]"
    refute data =~ "super-secret"
    refute data =~ "abc.def.ghi"

    assert [%{chunk: ^data}] = OutputStream.chunks(execution_id)
  end

  defp start_execution do
    {:ok, runner} = Fleet.register(%{hostname: "runner-failure-mode"})
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-failure"})
    {:ok, _claimed} = Assignments.claim(assignment.id, runner.id)
    {:ok, lease} = Fleet.acquire_lease(runner.id, assignment.id)
    execution_id = Ecto.UUID.generate()

    started = %Messages.ExecutionStarted{
      assignment_id: assignment.id,
      execution_id: execution_id,
      started_at: DateTime.utc_now()
    }

    envelope = Protocol.wrap(started, runner_id: runner.id, lease_id: lease.id)
    assert {:ok, running} = Protocol.send_to_controller(envelope)
    assert running.state == "running"

    %{assignment: assignment, runner: runner, lease: lease, execution_id: execution_id}
  end

  defp send_output(assignment_id, runner_id, lease_id, execution_id, chunk) do
    output = %Messages.OutputChunk{
      assignment_id: assignment_id,
      execution_id: execution_id,
      stream: "stdout",
      chunk: chunk,
      timestamp: DateTime.utc_now()
    }

    envelope = Protocol.wrap(output, runner_id: runner_id, lease_id: lease_id)
    assert {:ok, :observational_accepted} = Protocol.send_to_controller(envelope)
  end
end
