defmodule DevIDE.Loops.DriverTest do
  # Serial: mutates process-global Application env (:dev_ide DevIDE.Loops).
  use DevIde.DataCase, async: false

  alias DevIDE.Loops
  alias DevIDE.Loops.Driver
  alias DevIDE.LoopsTest.StubSeams.{RaisingGenerator, StubGenerator}

  setup do
    prev = Application.get_env(:dev_ide, DevIDE.Loops)

    Application.put_env(:dev_ide, DevIDE.Loops, Keyword.merge(prev || [], enabled: true))

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:dev_ide, DevIDE.Loops)
        val -> Application.put_env(:dev_ide, DevIDE.Loops, val)
      end
    end)

    :ok
  end

  # ── Deterministic seams ──────────────────────────────────────────────────
  # The generator encodes the round in its diff (via the iteration it is handed);
  # the sandbox maps that diff to a fixed objective evaluation. No model, no git,
  # no mix — just the control flow under test.

  # Improves over rounds: r1 won't compile, r2 compiles but target fails, r3 passes.
  defmodule ConvergingSandbox do
    @behaviour DevIDE.Loops.Sandbox
    @impl true
    def evaluate("round-1", _ctx), do: {:ok, base(%{compile_ok: false})}
    def evaluate("round-2", _ctx), do: {:ok, base(%{compile_ok: true, holdout_pass: true})}

    def evaluate("round-3", _ctx),
      do: {:ok, base(%{compile_ok: true, test_pass: true, holdout_pass: true})}

    defp base(overrides) do
      Map.merge(
        %{
          compile_ok: true,
          test_pass: false,
          holdout_pass: false,
          touched_test_files: false,
          added_rescue: false,
          new_failures: [],
          files_changed: ["lib/foo.ex"],
          output_excerpt: "..."
        },
        overrides
      )
    end
  end

  # Always "passes" the tests but by editing test files — a gamed attempt.
  defmodule GamingSandbox do
    @behaviour DevIDE.Loops.Sandbox
    @impl true
    def evaluate(_diff, _ctx) do
      {:ok,
       %{
         compile_ok: true,
         test_pass: true,
         holdout_pass: true,
         touched_test_files: true,
         added_rescue: false,
         new_failures: [],
         files_changed: ["test/foo_test.exs"],
         output_excerpt: "..."
       }}
    end
  end

  defp new_run(attrs \\ %{}) do
    {:ok, run} =
      Loops.create_run(Map.merge(%{target: "test/foo_test.exs:1", max_rounds: 3}, attrs))

    run
  end

  test "missing generator fails the run without running anything" do
    run = new_run()
    assert {:failed, run} = Driver.run_loop(run, [])
    assert run.status == :failed
    assert Loops.list_attempts(run) == []
  end

  test "disabled loops quarantine fails without attempts or generator calls" do
    Application.put_env(:dev_ide, DevIDE.Loops, enabled: false)
    run = new_run()

    assert {:failed, run} =
             Driver.run_loop(run,
               generator: RaisingGenerator,
               sandbox: ConvergingSandbox,
               root: "."
             )

    assert run.status == :failed
    assert Loops.list_attempts(run) == []
  end

  test "converges, persists an ascending-score ledger, and threads feedback" do
    run = new_run()

    assert {:converged, run} =
             Driver.run_loop(run,
               generator: StubGenerator,
               sandbox: ConvergingSandbox,
               root: "."
             )

    assert run.status == :converged
    assert run.converged

    attempts = Loops.list_attempts(run)
    assert Enum.map(attempts, & &1.iteration) == [1, 2, 3]
    # the fitness signal climbs round over round — the thing the prototype couldn't show
    assert Enum.map(attempts, & &1.score) == [0, 50, 100]

    # round 2's prompt carried round 1's result back in (feed-back)
    assert Enum.at(attempts, 1).feedback_in =~ "Round 1"

    won = Loops.best_attempt(run)
    assert won.score == 100
    assert won.verdict_legit
    refute won.verdict_gamed
  end

  test "a gamed pass never converges — it exhausts instead" do
    run = new_run(%{max_rounds: 2})

    assert {:exhausted, run} =
             Driver.run_loop(run,
               generator: StubGenerator,
               sandbox: GamingSandbox,
               root: "."
             )

    assert run.status == :exhausted
    refute run.converged

    attempts = Loops.list_attempts(run)
    assert length(attempts) == 2
    assert Enum.all?(attempts, & &1.verdict_gamed)
    assert Enum.all?(attempts, &(&1.touched_test_files and not &1.verdict_legit))
  end
end
