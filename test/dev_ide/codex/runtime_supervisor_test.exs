defmodule Casein.Codex.RuntimeSupervisorTest do
  use ExUnit.Case, async: false

  alias Casein.Codex.{Runtime, RuntimeSupervisor}

  @fixture Path.expand("../../fixtures/codex_app_server/fake_app_server.sh", __DIR__)

  test "registers and isolates an explicitly started runtime" do
    runtime_id = "runtime-supervised-#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             RuntimeSupervisor.start_runtime(
               workspace_id: "ws-supervised",
               runtime_id: runtime_id,
               cwd: File.cwd!(),
               executable: "/bin/sh",
               args: [@fixture]
             )

    on_exit(fn ->
      case RuntimeSupervisor.whereis(runtime_id) do
        nil -> :ok
        _pid -> RuntimeSupervisor.stop_runtime(runtime_id)
      end
    end)

    assert RuntimeSupervisor.whereis(runtime_id) == pid
    assert :ok = Runtime.await_ready(runtime_id)
    assert is_pid(Runtime.whereis_component(runtime_id, :event_router))
    assert is_pid(Runtime.whereis_component(runtime_id, :approval_broker))
    assert is_pid(Runtime.whereis_component(runtime_id, :app_server))
    ref = Process.monitor(pid)
    assert :ok = RuntimeSupervisor.stop_runtime(runtime_id)
    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}
    assert RuntimeSupervisor.whereis(runtime_id) == nil
  end
end
