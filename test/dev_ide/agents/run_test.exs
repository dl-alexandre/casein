defmodule DevIDE.Agents.RunTest do
  use DevIDE.TestCase, async: false
  alias DevIDE.Agents.{Run, Capability, ReviewCommand}

  setup_all do
    # erlexec backs Commands.spawn, which Run calls in init/1. It ships as an
    # `extra_applications` entry so it is normally already up, but ensure it
    # explicitly for self-containment.
    {:ok, _} = Application.ensure_all_started(:erlexec)
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "ar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # A harmless ReviewCommand that runs a real subprocess. We construct the
  # struct directly so init/1 spawns echo instead of the allowlist's `opencode`
  # binary (which need not exist on the box). start/5's allowlist gating is
  # exercised separately by the rejection tests below.
  defp echo_cmd(argv) do
    %ReviewCommand{
      id: "echo-test",
      argv: argv,
      requires: [],
      output_kind: :diagnostic,
      description: "test echo command"
    }
  end

  # Start the Run GenServer under the ExUnit supervisor (auto torn down at test
  # end) with a crafted ReviewCommand, so init/1 drives a real Commands.spawn.
  # Run.start_link/1 registers a name via the Agents.Registry, so each run gets
  # a unique workspace id. We override child_spec id to allow >1 per test.
  defp start_run(root, cmd, opts \\ []) do
    ws = "ws-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Run, {ws, root, cmd, opts}},
          id: {Run, ws}
        )
      )

    {ws, pid}
  end

  defp await_status(pid, want, tries \\ 100)
  defp await_status(_pid, _want, 0), do: :timeout

  defp await_status(pid, want, tries) do
    case Run.state(pid).status do
      ^want -> :ok
      :running -> Process.sleep(20) && await_status(pid, want, tries - 1)
      other -> {:unexpected, other}
    end
  end

  test "non-allowlisted id rejected", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"
    assert {:error, :not_allowed} = Run.start(ws, root, "rm -rf /", [])
    assert {:error, :not_allowed} = Run.start(ws, root, "opencode-pwn", [])
  end

  test "missing requires rejected", %{root: root} do
    ws = "ws-#{System.unique_integer([:positive])}"
    # No detected opencode capability
    assert {:error, :requires_not_met} = Run.start(ws, root, "opencode-version", [])

    assert {:error, :requires_not_met} =
             Run.start(ws, root, "opencode-version", [
               %Capability{kind: :opencode, status: :missing}
             ])
  end

  test "missing root rejected even when requires met" do
    ws = "ws-#{System.unique_integer([:positive])}"

    assert {:error, :no_root} =
             Run.start(ws, "/no/such/path", "opencode-version", [
               %Capability{kind: :opencode, status: :detected}
             ])
  end

  describe "lifecycle with a real subprocess" do
    test "init spawns echo, captures stdout, and reaches :succeeded with exit 0", %{root: root} do
      {ws, pid} = start_run(root, echo_cmd(["/bin/echo", "agent-hello"]))

      # snapshot/1 (via state/1) right after init reflects the running run.
      snap0 = Run.state(pid)
      assert snap0.workspace_id == ws
      assert snap0.id == "echo-test"
      assert snap0.argv == ["/bin/echo", "agent-hello"]
      assert snap0.output_kind == :diagnostic
      assert snap0.exit_code == nil
      assert is_struct(snap0.started_at, DateTime)

      assert :ok = await_status(pid, :succeeded)

      snap = Run.state(pid)
      assert snap.status == :succeeded
      assert snap.exit_code == 0
      assert is_struct(snap.finished_at, DateTime)
      assert snap.buffer =~ "agent-hello"
    end

    test "subscribe/2 returns a snapshot and streams data + exit to the subscriber", %{root: root} do
      # Run forwards cmd_data only to a subscriber attached at that moment
      # (earlier output is served via the snapshot buffer), so a bare echo races
      # subscribe/2 under load. Gate the output on a sync file we create only
      # after subscribing, so the forward branch is exercised deterministically.
      sync = Path.join(root, "stream-go")

      {ws, pid} =
        start_run(
          root,
          echo_cmd([
            "/bin/sh",
            "-c",
            "until [ -e '#{sync}' ]; do sleep 0.05; done; echo stream-me"
          ])
        )

      assert {:ok, snap} = Run.subscribe(pid)
      assert snap.workspace_id == ws
      File.touch!(sync)

      # handle_info({:cmd_data, ...}) forwards to subscriber; final exit too.
      assert_receive {:agent_run_data, ^ws, :stdout, data}, 5_000
      assert data =~ "stream-me"
      assert_receive {:agent_run_exit, ^ws, 0, :succeeded}, 5_000
    end

    test "subscribing twice demonitors the first subscriber", %{root: root} do
      {_ws, pid} = start_run(root, echo_cmd(["/bin/sleep", "5"]))
      assert {:ok, _} = Run.subscribe(pid)
      # Second subscribe takes the demonitor-old branch in handle_call.
      assert {:ok, _} = Run.subscribe(pid)
    end

    test "cancel/2 on an already-terminal run is a no-op", %{root: root} do
      {_ws, pid} = start_run(root, echo_cmd(["/bin/true"]))
      assert :ok = await_status(pid, :succeeded)
      # status != :running → second handle_cast(:cancel, state) clause.
      assert :ok = Run.cancel(pid)
      assert Run.state(pid).status == :succeeded
    end

    test "hard timeout fires for a slow command and yields :timed_out", %{root: root} do
      # Tiny timeout_ms against a long sleep guarantees :hard_timeout wins.
      {ws, pid} = start_run(root, echo_cmd(["/bin/sleep", "30"]), timeout_ms: 50)

      # The 50ms timer can fire before subscribe/2 is processed (exit is only
      # forwarded to an already-attached subscriber); the snapshot then reports
      # the terminal state instead.
      case Run.subscribe(pid) do
        {:ok, %{status: :timed_out}} ->
          :ok

        {:ok, _snap} ->
          assert_receive {:agent_run_exit, ^ws, :timeout, :timed_out}, 5_000
      end

      snap = Run.state(pid)
      assert snap.status == :timed_out
      assert snap.exit_code == :timeout
    end
  end

  describe "init failure" do
    test "unresolvable command argv stops the GenServer with {:spawn_failed, _}", %{root: root} do
      bogus = "devide-no-such-bin-#{System.unique_integer([:positive])}"
      ws = "ws-#{System.unique_integer([:positive])}"

      # Commands.spawn returns {:error, {:executable_not_found, _}}, so init/1
      # takes the {:stop, {:spawn_failed, reason}} branch. GenServer.start (no
      # link) returns the stop reason as {:error, reason}.
      assert {:error, {:spawn_failed, {:executable_not_found, ^bogus}}} =
               GenServer.start(Run, {ws, root, echo_cmd([bogus]), []})
    end
  end
end
