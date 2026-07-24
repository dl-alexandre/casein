defmodule Casein.AgentSessions.GrokACP.Transport.StdioTest do
  use ExUnit.Case, async: false

  alias Casein.AgentSessions.GrokACP.Transport.Stdio

  test "attach mode starts only the stdio bridge for an existing leader" do
    root =
      Path.join(
        System.tmp_dir!(),
        "devide-grok-stdio-#{System.unique_integer([:positive])}"
      )

    executable = Path.join(root, "fake-grok")
    socket = Path.join(root, "leader.sock")
    File.mkdir_p!(root)
    File.write!(socket, "existing leader sentinel")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    File.write!(
      executable,
      """
      #!/bin/bash
      printf '%s\\n' "$*" > /dev/tcp/127.0.0.1/#{port}
      cat >/dev/null
      """
    )

    File.chmod!(executable, 0o700)

    on_exit(fn ->
      :gen_tcp.close(listener)
      File.rm_rf!(root)
    end)

    assert {:ok, handle} =
             Stdio.start(self(),
               cwd: root,
               grok_executable: executable,
               leader_socket: socket,
               leader_mode: :attach,
               leader_timeout_ms: 100
             )

    assert {:ok, client} = :gen_tcp.accept(listener, 1_000)
    assert {:ok, call} = :gen_tcp.recv(client, 0, 1_000)
    :gen_tcp.close(client)

    ref = Process.monitor(handle.pid)
    assert :ok = Stdio.stop(handle)
    assert_receive {:DOWN, ^ref, :process, _pid, :normal}

    assert call =~ "agent --leader stdio"
    refute call =~ "agent leader"
  end
end
