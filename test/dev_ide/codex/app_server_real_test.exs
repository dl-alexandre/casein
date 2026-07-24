defmodule Casein.Codex.AppServerRealTest do
  use ExUnit.Case, async: false

  alias Casein.Codex.AppServer

  @codex_executable System.find_executable("codex")

  if @codex_executable do
    test "completes the initialize handshake with the installed Codex App Server" do
      codex_home =
        Path.join(
          if(File.dir?("/var/tmp"), do: "/var/tmp", else: System.tmp_dir!()),
          "devide-codex-real-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(codex_home)
      on_exit(fn -> File.rm_rf(codex_home) end)

      pid =
        start_supervised!(
          {AppServer,
           workspace_id: "ws-real-smoke",
           runtime_id: "runtime-real-smoke",
           cwd: File.cwd!(),
           executable: @codex_executable,
           args: ["app-server", "--stdio"],
           env: [
             {~c"CODEX_HOME", String.to_charlist(codex_home)},
             {~c"RUST_LOG", ~c"off"}
           ],
           subscriber: self(),
           initialize_timeout: 15_000}
        )

      assert :ok = AppServer.await_ready(pid, 15_000)
      assert %{status: :ready, metadata: metadata} = AppServer.status(pid)
      assert metadata.platform_family in ["unix", "windows"]
      assert is_binary(metadata.platform_os)
      assert is_binary(metadata.user_agent)

      assert {:ok, %{thread_id: thread_id, session_id: session_id}} =
               AppServer.start_thread(pid, %{}, 15_000)

      assert is_binary(thread_id)
      assert is_binary(session_id)
    end
  else
    @tag skip: "codex executable is not installed"
    test "completes the initialize handshake with the installed Codex App Server", do: :ok
  end
end
