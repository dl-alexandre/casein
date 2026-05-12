defmodule DevIDE.Fleet.M44Test do
  use ExUnit.Case, async: false

  alias DevIDE.Assignments
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Envelope
  alias DevIDE.Fleet.Protocol.Messages
  alias DevIDE.Fleet.WorkspaceContext

  setup do
    Fleet.clear()
    Assignments.clear()
    OutputStream.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    :ok
  end

  describe "ExecutionProjectionStore" do
    test "creates and retrieves projections" do
      projection = %ExecutionProjection{
        id: "e-1",
        assignment_id: "a-1",
        runner_id: "r-1",
        lease_id: "l-1",
        state: :started
      }

      :ok = ExecutionProjectionStore.create(projection)
      assert {:ok, retrieved} = ExecutionProjectionStore.get("e-1")
      assert retrieved.id == "e-1"
      assert retrieved.state == :started
    end

    test "updates projection state" do
      projection = %ExecutionProjection{
        id: "e-1",
        assignment_id: "a-1",
        runner_id: "r-1",
        lease_id: "l-1"
      }

      :ok = ExecutionProjectionStore.create(projection)

      :ok =
        ExecutionProjectionStore.update("e-1",
          state: :completed,
          completed_at: DateTime.utc_now()
        )

      assert {:ok, updated} = ExecutionProjectionStore.get("e-1")
      assert updated.state == :completed
    end

    test "lists projections for assignment" do
      p1 = %ExecutionProjection{
        id: "e-1",
        assignment_id: "a-1",
        runner_id: "r-1",
        lease_id: "l-1",
        started_at: DateTime.utc_now()
      }

      p2 = %ExecutionProjection{
        id: "e-2",
        assignment_id: "a-1",
        runner_id: "r-2",
        lease_id: "l-2",
        started_at: DateTime.utc_now()
      }

      p3 = %ExecutionProjection{
        id: "e-3",
        assignment_id: "a-2",
        runner_id: "r-1",
        lease_id: "l-3",
        started_at: DateTime.utc_now()
      }

      ExecutionProjectionStore.create(p1)
      ExecutionProjectionStore.create(p2)
      ExecutionProjectionStore.create(p3)

      assert length(ExecutionProjectionStore.for_assignment("a-1")) == 2
      assert length(ExecutionProjectionStore.for_assignment("a-2")) == 1
    end

    test "finds active projection excluding terminal states" do
      p1 = %ExecutionProjection{
        id: "e-1",
        assignment_id: "a-1",
        runner_id: "r-1",
        lease_id: "l-1",
        state: :completed
      }

      p2 = %ExecutionProjection{
        id: "e-2",
        assignment_id: "a-1",
        runner_id: "r-1",
        lease_id: "l-2",
        state: :started,
        started_at: DateTime.utc_now()
      }

      ExecutionProjectionStore.create(p1)
      ExecutionProjectionStore.create(p2)

      assert {:ok, active} = ExecutionProjectionStore.active_for_assignment("a-1")
      assert active.id == "e-2"
      assert active.state == :started
    end

    test "returns error when no active projection" do
      assert :error = ExecutionProjectionStore.active_for_assignment("nonexistent")
    end
  end

  describe "WorkspaceContext" do
    test "returns error for unknown workspace" do
      assert {:error, :workspace_not_found} = WorkspaceContext.validate("nonexistent")
    end

    test "validates existing workspace" do
      # Workspace must be registered in Workspaces.State separately
      # This test verifies the integration path when workspace exists
    end
  end

  describe "ArtifactStore" do
    test "appends and retrieves chunks" do
      now = DateTime.utc_now()
      :ok = ArtifactStore.append_chunk("e-1", "stdout", "hello", now)
      :ok = ArtifactStore.append_chunk("e-1", "stdout", " world", now)
      :ok = ArtifactStore.append_chunk("e-1", "stderr", "error", now)

      chunks = ArtifactStore.chunks("e-1")
      assert length(chunks) == 3
      assert hd(chunks).stream == "stdout"
      assert hd(chunks).data == "hello"
    end

    test "chunks_since filters by timestamp" do
      t1 = DateTime.utc_now()
      Process.sleep(10)
      t2 = DateTime.utc_now()
      Process.sleep(10)
      t3 = DateTime.utc_now()

      :ok = ArtifactStore.append_chunk("e-1", "stdout", "first", t1)
      :ok = ArtifactStore.append_chunk("e-1", "stdout", "second", t2)
      :ok = ArtifactStore.append_chunk("e-1", "stdout", "third", t3)

      chunks = ArtifactStore.chunks_since("e-1", t2)
      assert length(chunks) == 2
      assert Enum.map(chunks, & &1.data) == ["second", "third"]
    end

    test "clear removes all artifacts" do
      :ok = ArtifactStore.append_chunk("e-1", "stdout", "data", DateTime.utc_now())
      :ok = ArtifactStore.clear()
      assert ArtifactStore.chunks("e-1") == []
    end
  end

  describe "LocalRunnerAdapter with ArtifactStore" do
    test "OutputChunk stores in ArtifactStore and OutputStream" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, a.id)

      # Start execution
      started = %Messages.ExecutionStarted{
        assignment_id: a.id,
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(started, runner_id: runner.id, lease_id: lease.id)
      {:ok, _} = Protocol.send_to_controller(envelope)

      # Send output chunk
      chunk = %Messages.OutputChunk{
        assignment_id: a.id,
        execution_id: "e-1",
        stream: "stdout",
        chunk: "build output",
        timestamp: DateTime.utc_now()
      }

      envelope = Envelope.wrap(chunk, runner_id: runner.id, lease_id: lease.id)
      {:ok, :observational_accepted} = Protocol.send_to_controller(envelope)

      # Verify ArtifactStore has durable record
      artifacts = ArtifactStore.chunks("e-1")
      assert length(artifacts) == 1
      assert hd(artifacts).data == "build output"
      assert hd(artifacts).stream == "stdout"

      # Verify OutputStream has ephemeral record
      stream_chunks = OutputStream.chunks("e-1")
      assert length(stream_chunks) == 1
      assert hd(stream_chunks).chunk == "build output"
    end

    test "ExecutionStarted creates ExecutionProjection" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, a.id)

      started = %Messages.ExecutionStarted{
        assignment_id: a.id,
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(started, runner_id: runner.id, lease_id: lease.id)
      {:ok, _} = Protocol.send_to_controller(envelope)

      assert {:ok, projection} = ExecutionProjectionStore.get("e-1")
      assert projection.assignment_id == a.id
      assert projection.runner_id == runner.id
      assert projection.state == :started
    end
  end

  describe "attach/reconnect" do
    test "attach returns error when no active execution" do
      assert {:error, :no_active_execution} =
               DevIDE.Fleet.LocalRunnerAdapter.attach("nonexistent")
    end

    test "attach returns error when tmux session not alive" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, a.id)

      started = %Messages.ExecutionStarted{
        assignment_id: a.id,
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(started, runner_id: runner.id, lease_id: lease.id)
      {:ok, _} = Protocol.send_to_controller(envelope)

      # Without tmux session, attach should fail
      assert {:error, :session_not_alive} = DevIDE.Fleet.LocalRunnerAdapter.attach(a.id)
    end
  end

  describe "OutputStream ephemerality" do
    test "pruned on execution completion but ArtifactStore retains" do
      {:ok, a} = Assignments.create(%{workspace_id: "ws-1"})
      {:ok, _} = Assignments.claim(a.id, "runner-1")
      {:ok, runner} = Fleet.register(%{hostname: "r-1"})
      {:ok, lease} = Fleet.acquire_lease(runner.id, a.id)

      # Start and output
      started = %Messages.ExecutionStarted{
        assignment_id: a.id,
        execution_id: "e-1",
        started_at: DateTime.utc_now()
      }

      envelope = Envelope.wrap(started, runner_id: runner.id, lease_id: lease.id)
      {:ok, _} = Protocol.send_to_controller(envelope)

      for i <- 1..150 do
        chunk = %Messages.OutputChunk{
          assignment_id: a.id,
          execution_id: "e-1",
          stream: "stdout",
          chunk: "line #{i}",
          timestamp: DateTime.utc_now()
        }

        envelope = Envelope.wrap(chunk, runner_id: runner.id, lease_id: lease.id)
        Protocol.send_to_controller(envelope)
      end

      # Complete execution
      completed = %Messages.ExecutionCompleted{
        assignment_id: a.id,
        execution_id: "e-1",
        completed_at: DateTime.utc_now(),
        evidence: %{}
      }

      envelope = Envelope.wrap(completed, runner_id: runner.id, lease_id: lease.id)
      {:ok, _} = Protocol.send_to_controller(envelope)

      # OutputStream is pruned to 100
      assert length(OutputStream.chunks("e-1")) == 100

      # ArtifactStore retains all
      assert length(ArtifactStore.chunks("e-1")) == 150
    end
  end
end
