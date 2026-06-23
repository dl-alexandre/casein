defmodule DevIDE.Loops.Driver do
  @moduledoc """
  Orchestrates one loop run: generate → test → score → verify → feed back,
  bounded by the run's `max_rounds`, persisting every round to the attempt
  ledger and stopping on convergence.

  The three model/IO-bearing steps are injected (`:generator`, `:sandbox`,
  `:verifier`), so the control flow — the part that proves the score climbs and
  the loop converges — is exercised in tests with deterministic stubs.
  """

  require Logger

  alias DevIDE.Loops
  alias DevIDE.Loops.{Quarantine, Run, Scorer, Verifier}

  @type outcome :: :converged | :exhausted | :failed

  @doc """
  Run the loop for `run` to convergence or exhaustion.

  Options:

    * `:generator` (required) — module implementing `DevIDE.Loops.Generator`
    * `:sandbox` — `DevIDE.Loops.Sandbox` impl (default `Sandbox.Git`)
    * `:verifier` — `DevIDE.Loops.Verifier` impl (default `Verifier.impl/0`)
    * `:root` — repo working copy (default cwd / config)

  Returns `{outcome, %Run{}}` with the run reloaded in its terminal state.
  """
  @spec run_loop(Run.t(), keyword()) :: {outcome(), Run.t()}
  def run_loop(%Run{} = run, opts) do
    ctx = %{actor_type: :system, loop_run_id: run.id, workspace_id: Map.get(run, :workspace_id)}

    case Quarantine.authorize!(ctx) do
      :ok -> run_loop_authorized(run, opts)
      {:error, _reason} -> fail_run(run)
    end
  end

  defp run_loop_authorized(%Run{} = run, opts) do
    case Keyword.get(opts, :generator) do
      nil ->
        {:ok, run} = Loops.update_run(run, %{status: :failed})
        {:failed, run}

      generator ->
        sandbox = Keyword.get(opts, :sandbox, DevIDE.Loops.Sandbox.Git)
        verifier = Keyword.get(opts, :verifier, Verifier.impl())

        sandbox_ctx = %{
          root: root(opts),
          base_sha: run.base_sha,
          target: run.target,
          baseline_failures: run.baseline_failures
        }

        loop(run, %{generator: generator, sandbox: sandbox, verifier: verifier, ctx: sandbox_ctx})
    end
  end

  defp fail_run(%Run{} = run) do
    {:ok, run} = Loops.update_run(run, %{status: :failed})
    {:failed, run}
  end

  defp loop(run, seams) do
    init = {"First attempt — no prior feedback.", nil}

    result =
      Enum.reduce_while(1..run.max_rounds, init, fn iteration, {feedback, prior_diff} ->
        case round(run, seams, iteration, feedback, prior_diff) do
          {:converged, _attempt} -> {:halt, :converged}
          {:continue, next_feedback, diff} -> {:cont, {next_feedback, diff}}
        end
      end)

    finalize(run, result)
  end

  defp round(run, seams, iteration, feedback, prior_diff) do
    gen_ctx = %{
      target: run.target,
      baseline_failures: run.baseline_failures,
      feedback: feedback,
      prior_diff: prior_diff,
      iteration: iteration,
      root: seams.ctx.root
    }

    with {:ok, %{diff: diff} = gen} <- seams.generator.generate(gen_ctx),
         {:ok, eval} <- seams.sandbox.evaluate(diff, seams.ctx) do
      {score, breakdown} = Scorer.score(eval)
      {:ok, verdict} = seams.verifier.verify(diff, eval, seams.ctx)

      {:ok, _attempt} =
        Loops.record_attempt(
          run,
          attempt_attrs(iteration, diff, gen, eval, score, breakdown, verdict, feedback)
        )

      Logger.info(
        "loop #{run.id} round #{iteration}: score=#{score} (#{breakdown}) | " <>
          "legit=#{verdict.legit} gamed=#{verdict.gamed}"
      )

      if Scorer.solved?(eval, verdict) do
        {:converged, :ok}
      else
        {:continue, build_feedback(iteration, score, breakdown, eval, verdict), diff}
      end
    else
      {:error, reason} ->
        {:ok, _attempt} =
          Loops.record_attempt(run, %{
            iteration: iteration,
            diff: prior_diff,
            compile_ok: false,
            breakdown: "step error: #{inspect(reason)}",
            feedback_in: feedback
          })

        {:continue, "Previous round errored (#{inspect(reason)}); try a different approach.",
         prior_diff}
    end
  end

  defp attempt_attrs(iteration, diff, gen, eval, score, breakdown, verdict, feedback) do
    %{
      iteration: iteration,
      diff: diff,
      files_changed: Map.get(eval, :files_changed, []),
      compile_ok: eval.compile_ok,
      test_pass: eval.test_pass,
      holdout_pass: eval.holdout_pass,
      touched_test_files: eval.touched_test_files,
      added_rescue: eval.added_rescue,
      new_failures: Map.get(eval, :new_failures, []),
      score: score,
      breakdown: notes_breakdown(breakdown, gen),
      verdict_legit: verdict.legit,
      verdict_gamed: verdict.gamed,
      verdict_reason: verdict.reason,
      feedback_in: feedback
    }
  end

  defp notes_breakdown(breakdown, %{notes: notes}) when is_binary(notes) and notes != "",
    do: breakdown <> " | notes: " <> notes

  defp notes_breakdown(breakdown, _gen), do: breakdown

  defp finalize(run, :converged) do
    {:ok, run} = Loops.update_run(run, %{status: :converged, converged: true})
    {:converged, run}
  end

  defp finalize(run, _exhausted) do
    {:ok, run} = Loops.update_run(run, %{status: :exhausted})
    {:exhausted, run}
  end

  defp build_feedback(round, score, breakdown, eval, verdict) do
    [
      "Round #{round} did NOT pass. Score #{score} — #{breakdown}.",
      "Verifier: legit=#{verdict.legit}, gamed=#{verdict.gamed} — #{verdict.reason}",
      unless(eval.test_pass,
        do: "Frozen target still failing:\n" <> String.slice(eval.output_excerpt || "", 0, 1500)
      ),
      unless(eval.holdout_pass,
        do: "You introduced NEW failures: " <> inspect(Map.get(eval, :new_failures, []))
      ),
      "Fix the real defect in lib/; do not touch test/, do not game the metric."
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp root(opts) do
    Keyword.get(opts, :root) ||
      Application.get_env(:dev_ide, DevIDE.Loops, [])[:root] ||
      File.cwd!()
  end
end
