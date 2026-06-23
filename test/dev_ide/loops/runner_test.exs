defmodule DevIDE.Loops.RunnerTest do
  use DevIde.DataCase, async: false

  alias DevIDE.Audit
  alias DevIDE.Loops
  alias DevIDE.Loops.Runner
  alias DevIDE.LoopsTest.StubSeams.{FastExhaustSandbox, RaisingGenerator, StubGenerator}

  setup do
    prev = Application.get_env(:dev_ide, DevIDE.Loops)
    Audit.clear()

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, DevIDE.Loops)
        val -> Application.put_env(:dev_ide, DevIDE.Loops, val)
      end

      Audit.clear()
    end)

    :ok
  end

  defp new_run(attrs \\ %{}) do
    {:ok, run} =
      Loops.create_run(
        Map.merge(
          %{target: "test/foo_test.exs:1", max_rounds: 1, workspace_id: "ws-test-1"},
          attrs
        )
      )

    run
  end

  test "start denies without spawning when loops quarantine is disabled" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: false)
    run = new_run()

    assert {:error, :not_allowed} = Runner.start(run, generator: RaisingGenerator)

    assert [%{action: "policy.blocked", metadata: %{loop_run_id: loop_id}}] =
             Audit.list()
             |> Enum.filter(&(&1.action == "policy.blocked"))
             |> Enum.map(fn e ->
               %{action: e.action, metadata: e.metadata}
             end)

    assert loop_id == run.id
  end

  test "start spawns a supervised task when loops quarantine allows" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: true)
    run = new_run()

    assert {:ok, pid} =
             Runner.start(run,
               generator: StubGenerator,
               sandbox: FastExhaustSandbox,
               root: "."
             )

    assert is_pid(pid)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
  end
end
