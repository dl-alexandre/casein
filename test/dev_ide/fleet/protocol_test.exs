defmodule DevIDE.Fleet.ProtocolTest do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Fleet
  alias DevIDE.Fleet.Execution
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Envelope
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.Protocol.Validator

  setup do
    Fleet.clear()
    Assignments.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    :ok
  end

  describe "Execution struct" do
    test "constructs with defaults" do
      exec =
        Execution.new(
          id: "e-1",
          assignment_id: "a-1",
          runner_id: "r-1",
          lease_id: "l-1"
        )

      assert exec.id == "e-1"
      assert exec.state == :pending
      assert exec.evidence == %{}
    end
  end

  describe "Envelope.wrap/2" do
    test "wraps a message with all required fields" do
      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")

      assert envelope.version == 1
      assert envelope.runner_id == "r-1"
      assert envelope.lease_id == "l-1"
      assert is_binary(envelope.message_id)
      assert %DateTime{} = envelope.sent_at
      assert envelope.payload == msg
    end

    test "auto-generates message_id and sent_at" do
      msg = %Messages.Heartbeat{runner_id: "r-1"}

      envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")

      assert is_binary(envelope.message_id)
      assert %DateTime{} = envelope.sent_at
    end
  end

  describe "Envelope serialization round-trip" do
    test "serializes and deserializes state transition message" do
      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")
      map = Envelope.to_map(envelope)

      assert map["version"] == 1
      assert map["payload_type"] == "ExecutionStarted"
      assert map["payload"]["assignment_id"] == "a-1"

      {:ok, deserialized} = Envelope.from_map(map)
      assert deserialized.version == 1
      assert deserialized.runner_id == "r-1"
      assert deserialized.payload.assignment_id == "a-1"
    end

    test "serializes and deserializes observational message" do
      msg = %Messages.OutputChunk{
        assignment_id: "a-1",
        execution_id: "e-1",
        stream: "stdout",
        chunk: "hello world",
        timestamp: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")
      map = Envelope.to_map(envelope)

      {:ok, deserialized} = Envelope.from_map(map)
      assert deserialized.payload.stream == "stdout"
      assert deserialized.payload.chunk == "hello world"
    end

    test "serializes and deserializes lifecycle message" do
      msg = %Messages.LeaseRenewed{
        lease_id: "l-1",
        expires_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")
      map = Envelope.to_map(envelope)

      {:ok, deserialized} = Envelope.from_map(map)
      assert deserialized.payload.lease_id == "l-1"
      assert %DateTime{} = deserialized.payload.expires_at
    end

    test "returns error for unknown payload type" do
      map = %{
        "version" => 1,
        "message_id" => Ecto.UUID.generate(),
        "sent_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "runner_id" => "r-1",
        "lease_id" => "l-1",
        "payload_type" => "UnknownMessage",
        "payload" => %{}
      }

      assert {:error, :unknown_payload} = Envelope.from_map(map)
    end
  end

  describe "Message classification" do
    test "state transitions" do
      assert Messages.state_transition?(%Messages.ExecutionStarted{})
      assert Messages.state_transition?(%Messages.ExecutionCompleted{})
      assert Messages.state_transition?(%Messages.ExecutionFailed{})
      refute Messages.state_transition?(%Messages.OutputChunk{})
    end

    test "observational" do
      assert Messages.observational?(%Messages.OutputChunk{})
      assert Messages.observational?(%Messages.ArtifactChunk{})
      assert Messages.observational?(%Messages.Telemetry{})
      refute Messages.observational?(%Messages.ExecutionStarted{})
    end

    test "lifecycle" do
      assert Messages.lifecycle?(%Messages.Heartbeat{})
      assert Messages.lifecycle?(%Messages.LeaseRenewed{})
      refute Messages.lifecycle?(%Messages.ExecutionStarted{})
    end

    test "assignment_id extraction" do
      assert Messages.assignment_id(%Messages.ExecutionStarted{assignment_id: "a-1"}) == "a-1"
      assert Messages.assignment_id(%Messages.OutputChunk{assignment_id: "a-1"}) == "a-1"
      assert Messages.assignment_id(%Messages.Heartbeat{runner_id: "r-1"}) == nil
    end
  end

  describe "Protocol.classify/1" do
    test "classifies message types" do
      assert Protocol.classify(%Messages.ExecutionStarted{}) == :state_transition
      assert Protocol.classify(%Messages.OutputChunk{}) == :observational
      assert Protocol.classify(%Messages.Heartbeat{}) == :lifecycle
      assert Protocol.classify(%Messages.AssignmentOffered{}) == :control
    end
  end

  describe "Validator phase 1: envelope" do
    test "accepts valid envelope" do
      runner_id = Ecto.UUID.generate()
      lease_id = Ecto.UUID.generate()

      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner_id, lease_id: lease_id)
      assert {:error, :lease_not_found} = Validator.validate(envelope)
    end

    test "rejects invalid version" do
      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = %{Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1") | version: 999}
      assert {:error, {:invalid_version, 999, 1}} = Validator.validate(envelope)
    end

    test "rejects invalid message_id" do
      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = %{Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1") | message_id: "bad"}
      assert {:error, :invalid_message_id} = Validator.validate(envelope)
    end

    test "rejects invalid runner_id" do
      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = %{Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1") | runner_id: "bad"}
      assert {:error, :invalid_runner_id} = Validator.validate(envelope)
    end
  end

  describe "Validator phase 2: message structure" do
    test "rejects ExecutionStarted with missing fields" do
      runner_id = Ecto.UUID.generate()
      lease_id = Ecto.UUID.generate()
      msg = %Messages.ExecutionStarted{assignment_id: nil, execution_id: nil}
      envelope = Envelope.wrap(msg, runner_id: runner_id, lease_id: lease_id)
      assert {:error, :missing_execution_started_fields} = Validator.validate(envelope)
    end

    test "rejects ExecutionCompleted with missing fields" do
      runner_id = Ecto.UUID.generate()
      lease_id = Ecto.UUID.generate()

      msg = %Messages.ExecutionCompleted{
        assignment_id: "a-1",
        execution_id: nil,
        completed_at: nil
      }

      envelope = Envelope.wrap(msg, runner_id: runner_id, lease_id: lease_id)
      assert {:error, :missing_execution_completed_fields} = Validator.validate(envelope)
    end

    test "rejects OutputChunk with missing fields" do
      runner_id = Ecto.UUID.generate()
      lease_id = Ecto.UUID.generate()

      msg = %Messages.OutputChunk{
        assignment_id: "a-1",
        execution_id: "e-1",
        stream: nil,
        chunk: nil
      }

      envelope = Envelope.wrap(msg, runner_id: runner_id, lease_id: lease_id)
      assert {:error, :missing_output_chunk_fields} = Validator.validate(envelope)
    end
  end

  describe "Validator phase 3: lease validation" do
    test "rejects when lease does not exist" do
      runner_id = Ecto.UUID.generate()

      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner_id, lease_id: Ecto.UUID.generate())
      assert {:error, :lease_not_found} = Validator.validate(envelope)
    end

    test "rejects when lease belongs to different runner" do
      {:ok, r1} = Fleet.register(%{hostname: "r-1"})
      {:ok, r2} = Fleet.register(%{hostname: "r-2"})
      {:ok, lease} = Fleet.acquire_lease(r1.id, "a-1")

      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: r2.id, lease_id: lease.id)
      assert {:error, :lease_runner_mismatch} = Validator.validate(envelope)
    end

    test "rejects when lease is expired" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "a-1", duration_ms: -1)

      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)
      assert {:error, :lease_expired_or_inactive} = Validator.validate(envelope)
    end

    test "rejects when payload assignment does not match lease assignment" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "a-1")

      msg = %Messages.ExecutionStarted{
        assignment_id: "a-2",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)
      assert {:error, :lease_assignment_mismatch} = Validator.validate(envelope)
    end

    test "accepts when lease is active and belongs to runner" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "a-1")

      msg = %Messages.ExecutionStarted{
        assignment_id: "a-1",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)
      assert {:ok, ctx} = Validator.validate(envelope)
      assert ctx.lease.id == lease.id
    end

    test "rejects terminal transition before execution has started" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "a-1")

      msg = %Messages.ExecutionCompleted{
        assignment_id: "a-1",
        execution_id: "e-missing",
        completed_at: DateTime.utc_now(),
        evidence: %{exit_code: 0}
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)
      assert {:error, :execution_not_started} = Validator.validate(envelope)
    end

    test "rejects observational output before execution has started" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "a-1")

      msg = %Messages.OutputChunk{
        assignment_id: "a-1",
        execution_id: "e-missing",
        stream: "stdout",
        chunk: "hello",
        timestamp: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)
      assert {:error, :execution_not_started} = Validator.validate(envelope)
    end

    test "rejects observational output after execution is terminal" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, "a-1")

      :ok =
        ExecutionProjectionStore.create(%ExecutionProjection{
          id: "e-done",
          assignment_id: "a-1",
          runner_id: runner.id,
          lease_id: lease.id,
          state: :completed
        })

      msg = %Messages.OutputChunk{
        assignment_id: "a-1",
        execution_id: "e-done",
        stream: "stdout",
        chunk: "late",
        timestamp: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)
      assert {:error, :execution_not_active} = Validator.validate(envelope)
    end
  end

  describe "LocalRunnerAdapter.send_to_controller/1" do
    test "accepts and dispatches ExecutionStarted through full boundary" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, a.id)

      msg = %Messages.ExecutionStarted{
        assignment_id: a.id,
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)

      # Full boundary: serialize → deserialize → validate → dispatch
      assert {:ok, assignment} = Protocol.send_to_controller(envelope)
      assert assignment.state == "running"
    end

    test "rejects ExecutionStarted without valid lease" do
      msg = %Messages.ExecutionStarted{
        assignment_id: "nonexistent",
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: "r-1", lease_id: "l-1")
      assert {:error, _} = Protocol.send_to_controller(envelope)
    end

    test "observational message accepted without mutating state" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, running} = Assignments.start(a.id)
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, a.id)

      :ok =
        ExecutionProjectionStore.create(%ExecutionProjection{
          id: "e-1",
          assignment_id: a.id,
          runner_id: runner.id,
          lease_id: lease.id,
          state: :started,
          started_at: DateTime.utc_now()
        })

      msg = %Messages.OutputChunk{
        assignment_id: a.id,
        execution_id: "e-1",
        stream: "stdout",
        chunk: "hello",
        timestamp: DateTime.utc_now()
      }

      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: lease.id)

      # Should NOT change assignment state
      assert {:ok, :observational_accepted} = Protocol.send_to_controller(envelope)

      {:ok, assignment} = Assignments.get(a.id)
      assert assignment == running
    end

    test "heartbeat message accepted" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, a.id)

      msg = %Messages.Heartbeat{runner_id: runner.id}
      envelope = Envelope.wrap(msg, runner_id: runner.id, lease_id: a.id)

      assert {:ok, _} = Protocol.send_to_controller(envelope)
    end
  end

  describe "LocalRunnerAdapter.offer_assignment/2" do
    test "offers assignment to idle runner and accepts" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})

      offer = %Messages.AssignmentOffered{
        assignment_id: a.id,
        safe_action_id: "command:test",
        workspace_id: "ws-1",
        lease_duration_ms: 30_000
      }

      assert {:ok, %Messages.AssignmentAccepted{}, lease} =
               Protocol.offer_to_runner(runner.id, offer)

      assert lease != nil
      assert lease.assignment_id == a.id
      assert lease.runner_id == runner.id
    end

    test "offers assignment to busy runner and rejects" do
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, a1} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Fleet.acquire_lease(runner.id, a1.id)

      {:ok, a2} = Assignments.create(%{workspace_id: "ws-2"})

      offer = %Messages.AssignmentOffered{
        assignment_id: a2.id,
        safe_action_id: "command:test",
        workspace_id: "ws-2"
      }

      assert {:ok, %Messages.AssignmentRejected{reason: "runner_busy"}, nil} =
               Protocol.offer_to_runner(runner.id, offer)
    end
  end

  describe "Protocol end-to-end: offer → start → complete" do
    test "full execution lifecycle through protocol boundary" do
      # Setup
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")

      # Controller offers
      offer = %Messages.AssignmentOffered{
        assignment_id: a.id,
        safe_action_id: "command:test",
        workspace_id: "ws-1"
      }

      assert {:ok, %Messages.AssignmentAccepted{}, lease} =
               Protocol.offer_to_runner(runner.id, offer)

      # Runner reports execution started
      started = %Messages.ExecutionStarted{
        assignment_id: a.id,
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(started, runner_id: runner.id, lease_id: lease.id)
      assert {:ok, _} = Protocol.send_to_controller(envelope)

      # Verify state transition
      {:ok, assignment} = Assignments.get(a.id)
      assert assignment.state == "running"

      # Runner sends observational output (should not mutate state)
      output = %Messages.OutputChunk{
        assignment_id: a.id,
        execution_id: "e-1",
        stream: "stdout",
        chunk: "build output",
        timestamp: DateTime.utc_now()
      }

      envelope = Envelope.wrap(output, runner_id: runner.id, lease_id: lease.id)
      assert {:ok, :observational_accepted} = Protocol.send_to_controller(envelope)

      # Runner reports completion
      completed = %Messages.ExecutionCompleted{
        assignment_id: a.id,
        execution_id: "e-1",
        completed_at: DateTime.utc_now(),
        evidence: %{exit_code: 0}
      }

      envelope = Envelope.wrap(completed, runner_id: runner.id, lease_id: lease.id)
      assert {:ok, _} = Protocol.send_to_controller(envelope)

      # Verify final state
      {:ok, final} = Assignments.get(a.id)
      assert final.state == "completed"
    end
  end
end
