defmodule Scripts.GrokLeaderRuntimeTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/lib/grok-leader-runtime.py", __DIR__)

  setup do
    root =
      Path.join(System.tmp_dir!(), "grok-leader-runtime-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "spawns and authenticates one private process group from trusted metadata", %{root: root} do
    metadata = Path.join(root, ".casein-launcher")
    log = Path.join(root, "leader.log")

    assert {output, 0} =
             command(["spawn", metadata, log, "/bin/sh", "-c", "while :; do sleep 60; done"])

    pid = output |> String.trim() |> String.to_integer()

    on_exit(fn ->
      System.cmd("kill", ["-KILL", "--", "-#{pid}"], stderr_to_stdout: true)
    end)

    assert {identity, 0} = command(["identity", metadata])
    assert identity == "#{pid}\n"
    assert {_, 0} = command(["group-live", Integer.to_string(pid)])
    assert File.read!(metadata) =~ ~r/^#{pid} [0-9]+\n$/
    assert mode(metadata) == 0o600

    File.write!(metadata, "#{pid} 1\n")
    assert {error, 1} = command(["identity", metadata])
    assert error =~ "identity no longer matches"
  end

  test "performs a framed registration handshake and waits for leader_ready", %{root: root} do
    socket = Path.join(root, "leader.sock")
    server = Path.join(root, "server.py")

    File.write!(server, """
    import json, socket, struct, sys
    path = sys.argv[1]
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(1)
    print("ready", flush=True)
    client, _ = server.accept()
    def recv():
        size = struct.unpack(">I", client.recv(4))[0]
        data = b""
        while len(data) < size:
            data += client.recv(size - len(data))
        return json.loads(data)
    def send(value):
        data = json.dumps(value, separators=(",", ":")).encode()
        client.sendall(struct.pack(">I", len(data)) + data)
    assert recv()["type"] == "register"
    send({"type": "registered", "ready": False})
    send({"type": "leader_ready"})
    assert recv()["type"] == "disconnect"
    client.close()
    server.close()
    """)

    port =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        args: [server, socket],
        line: 1024
      ])

    assert_receive {^port, {:data, {:eol, "ready"}}}, 2_000
    assert {"", 0} = command(["probe", socket, "0", "2"])
    assert_receive {^port, {:exit_status, 0}}, 2_000
  end

  test "rejects group identity metadata that is writable by other users", %{root: root} do
    metadata = Path.join(root, ".casein-launcher")
    File.write!(metadata, "1 1\n")
    File.chmod!(metadata, 0o644)

    assert {error, 1} = command(["identity", metadata])
    assert error =~ "not private and owned"
  end

  test "kills the spawned process group when trusted metadata cannot be published", %{root: root} do
    leader_dir = Path.join(root, "leader")
    metadata = Path.join(leader_dir, ".casein-launcher")
    log = Path.join(System.tmp_dir!(), "grok-runtime-failed-#{System.unique_integer()}.log")
    marker = "casein-orphan-check-#{System.unique_integer([:positive])}"
    File.mkdir_p!(leader_dir)
    File.chmod!(root, 0o500)

    on_exit(fn ->
      File.chmod!(root, 0o700)
      File.rm(log)
    end)

    assert {error, 1} =
             command([
               "spawn",
               metadata,
               log,
               "/bin/bash",
               "-c",
               "exec -a #{marker} sleep 60"
             ])

    assert error =~ "Permission denied"
    {_output, status} = System.cmd("pgrep", ["-f", "^#{marker} 60$"])
    assert status == 1
  end

  test "resumes a quiesced leader only after the attaching process enters bwrap", %{root: root} do
    metadata = Path.join(root, ".casein-launcher")
    log = Path.join(root, "leader.log")
    assert {output, 0} = command(["spawn", metadata, log, "/bin/sh", "-c", "exec sleep 60"])
    leader_pid = output |> String.trim() |> String.to_integer()

    # Match the production npm topology: the exec'd wrapper remains alive and
    # the native/bwrap process carrying the marker is its descendant.
    tui =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "env __GROK_INSIDE_BWRAP=1 sleep 60 & wait"]
      ])

    {:os_pid, tui_pid} = Port.info(tui, :os_pid)

    on_exit(fn ->
      System.cmd("kill", ["-CONT", "--", "-#{leader_pid}"], stderr_to_stdout: true)
      System.cmd("kill", ["-KILL", "--", "-#{leader_pid}"], stderr_to_stdout: true)
      System.cmd("pkill", ["-KILL", "-P", Integer.to_string(tui_pid)], stderr_to_stdout: true)
      if Port.info(tui), do: Port.close(tui)
    end)

    refute File.read!("/proc/#{tui_pid}/environ") =~ "__GROK_INSIDE_BWRAP=1"

    assert {starttime, 0} = command(["process-starttime", Integer.to_string(tui_pid)])
    assert {_, 0} = System.cmd("kill", ["-STOP", "--", "-#{leader_pid}"])

    assert {"", 0} =
             command([
               "resume-after-sandbox",
               metadata,
               Integer.to_string(tui_pid),
               String.trim(starttime),
               "2"
             ])

    assert {_, 0} = command(["identity", metadata])
    refute process_state(leader_pid) == "T"
  end

  defp command(args) do
    System.cmd("python3", [@script | args], stderr_to_stdout: true)
  end

  defp mode(path) do
    {:ok, stat} = File.stat(path)
    Bitwise.band(stat.mode, 0o777)
  end

  defp process_state(pid) do
    stat = File.read!("/proc/#{pid}/stat")
    [state | _rest] = stat |> String.split(") ", parts: 2) |> List.last() |> String.split()
    state
  end
end
