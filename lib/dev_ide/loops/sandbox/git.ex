defmodule DevIDE.Loops.Sandbox.Git do
  @moduledoc """
  Production `DevIDE.Loops.Sandbox`: evaluates a candidate diff in a disposable
  git worktree, so the loop never mutates the live (possibly dirty) checkout.

  Per round it:

    1. `git worktree add --detach` a clean tree at `base_sha`
    2. `git apply` the candidate diff (apply failure ⇒ `compile_ok: false`)
    3. analyzes the diff for gaming signals (`Sandbox.analyze_diff/1`)
    4. `mix compile` (hard gate)
    5. `mix test <target>` — the frozen target
    6. `mix test` — held-out; `new_failures` = failing ids minus baseline minus target
    7. removes the worktree

  The `mix` invocation is configurable (`config :dev_ide, DevIDE.Loops,
  mix_cmd: {cmd, base_args}`); the default wraps the repo's pinned toolchain and
  unsets the env that would otherwise bind port 4000 / the wrong DB in test
  (see CLAUDE.md and the test-env quirk).
  """
  @behaviour DevIDE.Loops.Sandbox

  alias DevIDE.Loops.Sandbox

  require Logger

  @default_mix_cmd {"env",
                    [
                      "-u",
                      "PHX_SERVER",
                      "-u",
                      "DATABASE_URL",
                      "mise",
                      "exec",
                      "elixir@1.20.0-otp-28",
                      "erlang@28.5",
                      "--",
                      "mix"
                    ]}

  @test_id_regex ~r{test/[\w./-]+_test\.exs:\d+}

  @impl true
  def evaluate(diff, %{root: root} = ctx) when is_binary(diff) do
    base = Map.get(ctx, :base_sha) || "HEAD"
    worktree = Path.join(System.tmp_dir!(), "devide-loop-#{System.unique_integer([:positive])}")

    with :ok <- add_worktree(root, worktree, base) do
      try do
        {:ok, evaluate_in(worktree, diff, ctx)}
      after
        remove_worktree(root, worktree)
      end
    end
  end

  defp evaluate_in(worktree, diff, ctx) do
    signals = Sandbox.analyze_diff(diff)

    case apply_diff(worktree, diff) do
      :ok ->
        run_checks(worktree, diff, ctx, signals)

      {:error, output} ->
        base_eval(signals, diff)
        |> Map.merge(%{
          compile_ok: false,
          output_excerpt: "diff did not apply:\n" <> trim(output)
        })
    end
  end

  defp run_checks(worktree, diff, ctx, signals) do
    {_compile_out, compile_status} = mix(worktree, ["compile"])

    if compile_status != 0 do
      base_eval(signals, diff)
      |> Map.merge(%{compile_ok: false, output_excerpt: "mix compile failed"})
    else
      {target_out, target_status} = mix(worktree, ["test", ctx.target])
      {holdout_out, _holdout_status} = mix(worktree, ["test"])

      new_failures = new_failures(holdout_out, ctx)

      base_eval(signals, diff)
      |> Map.merge(%{
        compile_ok: true,
        test_pass: target_status == 0,
        holdout_pass: new_failures == [],
        new_failures: new_failures,
        output_excerpt: trim(if(target_status == 0, do: holdout_out, else: target_out))
      })
    end
  end

  defp base_eval(signals, diff) do
    %{
      compile_ok: false,
      test_pass: false,
      holdout_pass: false,
      new_failures: [],
      touched_test_files: signals.touched_test_files,
      added_rescue: signals.added_rescue,
      files_changed: changed_files(diff),
      output_excerpt: ""
    }
  end

  # Failing test ids in the held-out run that are neither pre-existing baseline
  # failures nor the frozen target itself. Heuristic: scan for `test/…:NN` tokens.
  defp new_failures(output, ctx) do
    known = MapSet.new([ctx.target | Map.get(ctx, :baseline_failures, [])])

    @test_id_regex
    |> Regex.scan(output)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(known, &1))
  end

  defp changed_files(diff) do
    ~r{^\+\+\+ b/(.+)$}m
    |> Regex.scan(diff)
    |> Enum.map(fn [_, path] -> path end)
    |> Enum.uniq()
  end

  defp add_worktree(root, worktree, base) do
    case git(root, ["worktree", "add", "--detach", worktree, base]) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:worktree_add_failed, status, trim(out)}}
    end
  end

  defp remove_worktree(root, worktree) do
    _ = git(root, ["worktree", "remove", "--force", worktree])
    _ = File.rm_rf(worktree)
    :ok
  end

  defp apply_diff(_worktree, ""), do: :ok

  defp apply_diff(worktree, diff) do
    patch = Path.join(worktree, ".loop-candidate.diff")
    File.write!(patch, diff)

    try do
      case git(worktree, ["apply", "--whitespace=nowarn", patch]) do
        {_out, 0} -> :ok
        {out, _status} -> {:error, out}
      end
    after
      _ = File.rm(patch)
    end
  end

  defp git(cd, args), do: System.cmd("git", args, cd: cd, stderr_to_stdout: true)

  defp mix(worktree, args) do
    {cmd, base_args} =
      Application.get_env(:dev_ide, DevIDE.Loops, [])[:mix_cmd] || @default_mix_cmd

    System.cmd(cmd, base_args ++ args, cd: worktree, stderr_to_stdout: true)
  rescue
    error ->
      Logger.warning("loop sandbox mix invocation failed: #{inspect(error)}")
      {"mix invocation error: #{inspect(error)}", 1}
  end

  defp trim(output) when is_binary(output), do: output |> String.slice(0, 4000)
  defp trim(output), do: inspect(output)
end
