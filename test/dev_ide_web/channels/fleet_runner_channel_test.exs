defmodule DevIdeWeb.FleetRunnerChannelTest do
  use DevIdeWeb.ConnCase, async: false

  import Phoenix.ChannelTest

  alias DevIDE.Assignments
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.AssignmentRequirements
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.Protocol
  alias DevIDE.Fleet.Protocol.Messages

  @endpoint DevIdeWeb.Endpoint
  @token "fleet-channel-token"

  setup do
    previous_token = Application.get_env(:dev_ide, :api_token)
    Application.put_env(:dev_ide, :api_token, @token)

    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()

      if previous_token do
        Application.put_env(:dev_ide, :api_token, previous_token)
      else
        Application.delete_env(:dev_ide, :api_token)
      end
    end)

    :ok
  end

  test "channel negotiates protocol, offers work, and accepts protocol envelopes" do
    runner_id = Ecto.UUID.generate()

    {:ok, _runner} =
      Fleet.register(%{
        id: runner_id,
        hostname: "channel-runner",
        capabilities: ["workspace-command:v1"]
      })

    assignment = enqueue_assignment()

    {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.FleetRunnerSocket, %{"token" => @token})

    assert {:ok, join_reply, socket} =
             subscribe_and_join(socket, "runner:#{runner_id}", %{"protocol_version" => 1})

    assert join_reply.protocol_version == 1
    assert join_reply.transport == "devide.fleet.channel.v1"

    ref = Phoenix.ChannelTest.push(socket, "poll_offer", %{"timeout_ms" => 0})
    assert_reply ref, :ok, offer
    assert offer.envelope["payload_type"] == "AssignmentOffered"
    assert offer.assignment.id == assignment.id

    lease_id = offer.lease.id
    execution_id = Ecto.UUID.generate()

    started =
      %Messages.ExecutionStarted{
        assignment_id: assignment.id,
        execution_id: execution_id,
        started_at: DateTime.utc_now()
      }
      |> Protocol.wrap(runner_id: runner_id, lease_id: lease_id)
      |> Protocol.serialize()

    ref = Phoenix.ChannelTest.push(socket, "message", %{"envelope" => started})
    assert_reply ref, :ok, %{result: %{assignment: %{state: "running"}}}

    completed =
      %Messages.ExecutionCompleted{
        assignment_id: assignment.id,
        execution_id: execution_id,
        completed_at: DateTime.utc_now(),
        evidence: %{exit_code: 0}
      }
      |> Protocol.wrap(runner_id: runner_id, lease_id: lease_id)
      |> Protocol.serialize()

    ref = Phoenix.ChannelTest.push(socket, "message", %{"envelope" => completed})
    assert_reply ref, :ok, %{result: %{assignment: %{state: "completed"}}}
  end

  test "channel rejects unsupported protocol versions" do
    runner_id = Ecto.UUID.generate()
    {:ok, _runner} = Fleet.register(%{id: runner_id, hostname: "channel-runner"})
    {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.FleetRunnerSocket, %{"token" => @token})

    assert {:error, %{reason: reason}} =
             subscribe_and_join(socket, "runner:#{runner_id}", %{"protocol_version" => 99})

    assert reason =~ "unsupported_protocol_version"
  end

  test "channel rejects revoked runner on reconnect" do
    runner_id = Ecto.UUID.generate()
    {:ok, _runner} = Fleet.register(%{id: runner_id, hostname: "channel-runner"})
    {:ok, _identity} = Fleet.set_runner_trust_state(runner_id, :revoked)
    {:ok, socket} = Phoenix.ChannelTest.connect(DevIdeWeb.FleetRunnerSocket, %{"token" => @token})

    assert {:error, %{reason: "runner_revoked"}} =
             subscribe_and_join(socket, "runner:#{runner_id}", %{"protocol_version" => 1})
  end

  test "channel reconnect resumes execution and artifact state from durable stores" do
    runner_id = Ecto.UUID.generate()
    {:ok, _runner} = Fleet.register(%{id: runner_id, hostname: "channel-runner"})
    {:ok, assignment} = Assignments.create(%{workspace_id: "ws-channel"})
    execution_id = Ecto.UUID.generate()

    :ok =
      ExecutionProjectionStore.create(%ExecutionProjection{
        id: execution_id,
        assignment_id: assignment.id,
        runner_id: runner_id,
        lease_id: Ecto.UUID.generate(),
        state: :started,
        started_at: DateTime.utc_now()
      })

    :ok =
      ArtifactStore.append_chunk(execution_id, "stdout", "durable output\n", DateTime.utc_now())

    {:ok, first_socket} =
      Phoenix.ChannelTest.connect(DevIdeWeb.FleetRunnerSocket, %{"token" => @token})

    assert {:ok, _join_reply, _socket} =
             subscribe_and_join(first_socket, "runner:#{runner_id}", %{"protocol_version" => 1})

    {:ok, reconnect_socket} =
      Phoenix.ChannelTest.connect(DevIdeWeb.FleetRunnerSocket, %{"token" => @token})

    assert {:ok, _join_reply, reconnect_socket} =
             subscribe_and_join(reconnect_socket, "runner:#{runner_id}", %{
               "protocol_version" => 1
             })

    ref =
      Phoenix.ChannelTest.push(reconnect_socket, "resume", %{"assignment_id" => assignment.id})

    assert_reply ref, :ok, resume

    assert Enum.any?(resume.executions, &(&1.id == execution_id))
    assert [%{data: "durable output\n", execution_id: ^execution_id}] = resume.artifacts
  end

  defp enqueue_assignment do
    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-channel",
        metadata: %{safe_action_id: "command:format", command_id: "format"}
      })

    :ok =
      DevIDE.Fleet.Queue.enqueue(
        assignment.id,
        AssignmentRequirements.new(capabilities: ["workspace-command:v1"], max_runtime_ms: 30_000)
      )

    assignment
  end
end
