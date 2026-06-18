defmodule DevIDE.Fleet.RemoteRunnerTest do
  use ExUnit.Case, async: false

  # These assert on messages from a fast polling/heartbeat runner (poll_ms: 10).
  # The bound is a ceiling, not a delay — assert_receive returns the instant the
  # message matches, so the happy path is unaffected. A tight 500ms (or the
  # implicit 100ms default) flakes only under full-suite scheduler contention
  # (hundreds of async tests + PTY-spawning terminal tests starving the BEAM
  # schedulers), never in isolation. Generous headroom removes the flake.
  @receive_timeout 15_000

  alias DevIDE.Assignments
  alias DevIDE.Workspace
  alias DevIDE.Fleet
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.AssignmentRequirements
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Fleet.Notification
  alias DevIDE.Fleet.OutputStream
  alias DevIDE.Fleet.RemoteRunner
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter, as: WorkspaceState

  setup do
    previous_adapter = Application.get_env(:dev_ide, :commands_adapter)
    previous_test_pid = Application.get_env(:dev_ide, :fake_command_test_pid)

    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeCommandAdapter)
    Application.put_env(:dev_ide, :fake_command_test_pid, self())

    Fleet.clear()
    DevIDE.Fleet.Queue.clear()
    DevIDE.Fleet.RunnerDirectory.clear()
    Assignments.clear()
    OutputStream.clear()
    ExecutionProjectionStore.clear()
    ArtifactStore.clear()
    WorkspaceState.clear()

    on_exit(fn ->
      Fleet.clear()
      DevIDE.Fleet.Queue.clear()
      DevIDE.Fleet.RunnerDirectory.clear()
      Assignments.clear()
      OutputStream.clear()
      ExecutionProjectionStore.clear()
      ArtifactStore.clear()
      WorkspaceState.clear()

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
  test "standalone runner polls, executes, uploads artifacts, and completes", %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)
    assignment = enqueue_assignment("format")

    {:ok, _pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: Ecto.UUID.generate(),
        hostname: "remote-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        notify_pid: self()
      )

    assert_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]},
                   @receive_timeout

    assignment_id = assignment.id

    assert_receive {:remote_runner_finished,
                    %{status: :completed, assignment_id: ^assignment_id}},
                   @receive_timeout

    assert {:ok, final} = Assignments.get(assignment.id)
    assert final.state == "completed"

    [execution] = ExecutionProjectionStore.for_assignment(assignment.id)
    assert execution.state == :completed
    assert [%{stream: "stdout", data: "ok\n"}] = ArtifactStore.chunks(execution.id)
  end

  @tag :tmp_dir
  test "runner renews a live lease while command is still executing", %{tmp_dir: tmp_dir} do
    Application.put_env(:dev_ide, :commands_adapter, DevIDE.Test.FakeSlowCommandAdapter)
    seed_workspace(tmp_dir)
    assignment = enqueue_assignment("compile", max_runtime_ms: 30_000)
    Phoenix.PubSub.subscribe(DevIde.PubSub, "fleet:assignments:#{assignment.id}")

    {:ok, _pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: Ecto.UUID.generate(),
        hostname: "renew-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        renew_ms: 10,
        notify_pid: self()
      )

    assert_receive {:fake_slow_command_spawned, ^tmp_dir, ["mix", "compile"], command_pid, _ref},
                   @receive_timeout

    assert_receive {DevIDE.Fleet.Registry,
                    %Notification{kind: :lease_renewed, assignment_id: assignment_id}},
                   @receive_timeout

    assert assignment_id == assignment.id

    send(command_pid, {:finish, 0})

    assert_receive {:remote_runner_finished, %{status: :completed, assignment_id: assignment_id}},
                   @receive_timeout

    assert assignment_id == assignment.id
  end

  @tag :tmp_dir
  test "runner clears active_task when executor task crashes", %{tmp_dir: tmp_dir} do
    seed_workspace(tmp_dir)
    _assignment = enqueue_assignment("format")

    {:ok, pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: Ecto.UUID.generate(),
        hostname: "crash-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        executor: DevIDE.Fleet.RemoteRunnerTest.CrashingExecutor,
        notify_pid: self()
      )

    assert_receive {:remote_runner_failed, _reason}, @receive_timeout

    assert %{active_task: nil, active_offer: nil, active_lease_id: nil} =
             RemoteRunner.snapshot(pid)
  end

  @tag :tmp_dir
  test "runner drain stops polling new work and shutdown marks runner offline", %{
    tmp_dir: tmp_dir
  } do
    seed_workspace(tmp_dir)
    runner_id = Ecto.UUID.generate()

    {:ok, pid} =
      RemoteRunner.start_link(
        transport: DevIDE.Fleet.RemoteRunner.LocalTransport,
        runner_id: runner_id,
        hostname: "drain-runner",
        capabilities: ["workspace-command:v1"],
        poll_ms: 10,
        heartbeat_ms: 20,
        notify_pid: self()
      )

    assert {:ok, snapshot} = RemoteRunner.drain(pid)
    assert snapshot.draining == true
    assert {:ok, %{state: :draining}} = Fleet.get_runner(runner_id)

    _assignment = enqueue_assignment("format")
    refute_receive {:fake_command_spawned, ^tmp_dir, ["mix", "format", "--check-formatted"]}, 100

    assert :ok = RemoteRunner.shutdown(pid)
    assert {:ok, %{state: :offline}} = Fleet.get_runner(runner_id)
  end

  defp enqueue_assignment(command_id, opts \\ []) do
    {:ok, assignment} =
      Assignments.create(%{
        workspace_id: "ws-runner",
        metadata: %{
          safe_action_id: "command:#{command_id}",
          command_id: command_id,
          concurrency_group: Keyword.get(opts, :concurrency_group)
        }
      })

    :ok =
      DevIDE.Fleet.Queue.enqueue(
        assignment.id,
        AssignmentRequirements.new(
          capabilities: ["workspace-command:v1"],
          max_runtime_ms: Keyword.get(opts, :max_runtime_ms, 30_000)
        )
      )

    assignment
  end

  defmodule CrashingExecutor do
    def run(_offer, _report_fun, _opts), do: raise("executor crash")
  end

  # Scriptable transport backed by an Agent reply queue. Each heartbeat/poll/
  # register call pops the next scripted reply and echoes the call to the test
  # pid, so we can drive the GenServer deterministically with :heartbeat /
  # :poll messages. The Agent (not transport_state) holds the queues because
  # the Transport.poll_offer/2 callback returns no state, so poll consumption
  # cannot be threaded through transport_state.
  defmodule ScriptedTransport do
    @behaviour DevIDE.Fleet.RemoteRunner.Transport

    alias FleetCtl.Protocol.Envelope

    # The test owns the Agent (passed in via :script_agent) so it can push new
    # scripted replies after start_link without reaching into transport_state.
    def new_agent(replies \\ []) do
      Agent.start_link(fn ->
        %{
          heartbeat: Keyword.get(replies, :heartbeat, []),
          poll: Keyword.get(replies, :poll, []),
          register: Keyword.get(replies, :register, [])
        }
      end)
    end

    # Pushes scripted replies for `key` (:heartbeat | :poll | :register).
    def script(agent, key, replies) do
      Agent.update(agent, fn queues -> Map.put(queues, key, replies) end)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         runner_id: Keyword.get(opts, :runner_id) || Ecto.UUID.generate(),
         test_pid: Keyword.fetch!(opts, :test_pid),
         agent: Keyword.fetch!(opts, :script_agent)
       }}
    end

    @impl true
    def register(state) do
      send(state.test_pid, {:transport, :register})
      pop(state, :register, {:ok, state})
    end

    @impl true
    def heartbeat(state) do
      send(state.test_pid, {:transport, :heartbeat})
      pop(state, :heartbeat, {:ok, state})
    end

    @impl true
    def poll_offer(state, _opts) do
      send(state.test_pid, {:transport, :poll})
      pop(state, :poll, :none)
    end

    @impl true
    def drain(state), do: {:ok, state}

    @impl true
    def shutdown(state), do: {:ok, state}

    @impl true
    def send_envelope(_state, %Envelope{}), do: {:ok, %{}}

    # Pops the next scripted reply for `key`; falls back to `default` once
    # exhausted. `{:ok, _}` is normalized to `{:ok, state}`, errors pass
    # through, and `:none` is the poll-empty marker.
    defp pop(state, key, default) do
      next =
        Agent.get_and_update(state.agent, fn queues ->
          case Map.fetch!(queues, key) do
            [head | rest] -> {head, Map.put(queues, key, rest)}
            [] -> {default, queues}
          end
        end)

      case next do
        :none -> :none
        {:ok, _} -> {:ok, state}
        {:error, _} = err -> err
      end
    end
  end

  describe "404 recovery" do
    test "re-registers when heartbeat returns 404 and resets backoff on success" do
      {:ok, agent} = ScriptedTransport.new_agent()
      pid = start_scripted_runner(agent)

      # init/1 registers once.
      assert_receive {:transport, :register}, @receive_timeout

      # First heartbeat 404s -> runner must re-register under the same id.
      ScriptedTransport.script(agent, :heartbeat, [{:error, {:http_status, 404}}])
      send(pid, :heartbeat)
      assert_receive {:transport, :heartbeat}, @receive_timeout
      assert_receive {:transport, :register}, @receive_timeout

      # Re-register succeeded -> failure counter reset to 0.
      assert %{heartbeat_failures: 0} = RemoteRunner.snapshot(pid)
    end

    test "poll re-registers on 404 and resumes normal polling after recovery" do
      {:ok, agent} = ScriptedTransport.new_agent()
      pid = start_scripted_runner(agent)

      assert_receive {:transport, :register}, @receive_timeout

      ScriptedTransport.script(agent, :poll, [
        {:error, {:http_status, 404, %{"error" => "not_found"}}}
      ])

      send(pid, :poll)
      assert_receive {:transport, :poll}, @receive_timeout
      assert_receive {:transport, :register}, @receive_timeout
      assert %{poll_failures: 0} = RemoteRunner.snapshot(pid)

      # Next poll is a normal :none -> still healthy, no re-register.
      send(pid, :poll)
      assert_receive {:transport, :poll}, @receive_timeout
      refute_receive {:transport, :register}, 100
      assert %{poll_failures: 0} = RemoteRunner.snapshot(pid)
    end

    test "consecutive failures back off instead of staying at the fixed interval" do
      # Re-register keeps failing, so the unknown-runner condition persists and
      # the failure counter must climb (driving exponential backoff).
      {:ok, agent} =
        ScriptedTransport.new_agent(
          register: [
            # First reply is consumed by init/1's register (must succeed).
            {:ok, :init},
            {:error, {:http_status, 500}},
            {:error, {:http_status, 500}},
            {:error, {:http_status, 500}}
          ]
        )

      pid = start_scripted_runner(agent)
      assert_receive {:transport, :register}, @receive_timeout

      ScriptedTransport.script(agent, :heartbeat, [
        {:error, {:http_status, 404}},
        {:error, {:http_status, 404}},
        {:error, {:http_status, 404}}
      ])

      send(pid, :heartbeat)
      assert_receive {:transport, :heartbeat}, @receive_timeout
      assert %{heartbeat_failures: 1} = RemoteRunner.snapshot(pid)

      send(pid, :heartbeat)
      assert_receive {:transport, :heartbeat}, @receive_timeout
      assert %{heartbeat_failures: 2} = RemoteRunner.snapshot(pid)

      send(pid, :heartbeat)
      assert_receive {:transport, :heartbeat}, @receive_timeout
      assert %{heartbeat_failures: 3} = RemoteRunner.snapshot(pid)
    end

    test "revoked (403) does NOT trigger re-register and stays down" do
      {:ok, agent} = ScriptedTransport.new_agent()
      pid = start_scripted_runner(agent)

      assert_receive {:transport, :register}, @receive_timeout

      # 403 == runner_revoked: a revoked runner must NOT come back to life.
      ScriptedTransport.script(agent, :heartbeat, [{:error, {:http_status, 403}}])
      send(pid, :heartbeat)
      assert_receive {:transport, :heartbeat}, @receive_timeout
      refute_receive {:transport, :register}, 100

      # It still backs off (failure counter climbs) rather than re-registering.
      assert %{heartbeat_failures: 1} = RemoteRunner.snapshot(pid)
    end
  end

  # Starts a runner on the scripted transport with intervals large enough that
  # auto-scheduled timers never fire; tests drive it by hand with :heartbeat /
  # :poll messages.
  defp start_scripted_runner(agent) do
    {:ok, pid} =
      RemoteRunner.start_link(
        transport: ScriptedTransport,
        runner_id: Ecto.UUID.generate(),
        heartbeat_ms: 600_000,
        poll_ms: 600_000,
        script_agent: agent,
        test_pid: self()
      )

    pid
  end

  defp seed_workspace(path) do
    {:ok, _record} =
      State.sync(%Workspace{
        id: "ws-runner",
        name: "Runner",
        user: "operator",
        branch: "main",
        status: :running,
        path: path,
        metadata: %{"id" => "ws-runner", "branch" => "main"}
      })
  end
end
