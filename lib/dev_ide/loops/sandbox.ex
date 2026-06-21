defmodule DevIDE.Loops.Sandbox do
  @moduledoc """
  The "test" seam — applies a candidate diff and measures it objectively.

  This is where anti-gaming is enforced mechanically: the sandbox runs the
  frozen target test and the held-out suite itself, and derives the gaming
  signals (`touched_test_files`, `added_rescue`) from the diff text — none of it
  is taken on the generator's word.

  `DevIDE.Loops.Sandbox.Git` is the production implementation (isolated git
  worktree + `mix`); tests inject a stub.
  """

  @typedoc """
  Context for evaluation.

    * `:root` — repo working copy whose `.git` backs the worktree
    * `:base_sha` — commit the disposable worktree is created from
    * `:target` — frozen target test id
    * `:baseline_failures` — failing ids that predate this loop (excluded from `new_failures`)
  """
  @type context :: %{
          root: String.t(),
          base_sha: String.t() | nil,
          target: String.t(),
          baseline_failures: [String.t()]
        }

  @typedoc "Objective measurement of a candidate diff."
  @type eval :: %{
          compile_ok: boolean(),
          test_pass: boolean(),
          holdout_pass: boolean(),
          new_failures: [String.t()],
          touched_test_files: boolean(),
          added_rescue: boolean(),
          files_changed: [String.t()],
          output_excerpt: String.t()
        }

  @callback evaluate(diff :: String.t(), context()) :: {:ok, eval()} | {:error, term()}

  @doc """
  Static analysis of a unified diff for gaming signals, shared by sandbox
  implementations. Pure so it is independently testable.

    * `touched_test_files` — any added/removed file path under `test/`
    * `added_rescue` — an added line that opens a bare `rescue`/`catch`
      (no exception struct), the classic "swallow the error to go green"
  """
  @spec analyze_diff(String.t()) :: %{touched_test_files: boolean(), added_rescue: boolean()}
  def analyze_diff(diff) when is_binary(diff) do
    lines = String.split(diff, "\n")

    touched_test_files =
      Enum.any?(lines, fn line ->
        (String.starts_with?(line, "+++ ") or String.starts_with?(line, "--- ")) and
          String.contains?(line, "test/")
      end)

    added_rescue =
      lines
      |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
      |> Enum.map(&(&1 |> String.trim_leading("+") |> String.trim()))
      |> Enum.any?(&bare_rescue?/1)

    %{touched_test_files: touched_test_files, added_rescue: added_rescue}
  end

  # A bare `rescue` / `catch` with no exception pattern after it swallows
  # everything; `rescue e in RuntimeError ->` is fine.
  defp bare_rescue?(line) do
    line in ["rescue", "catch"] or
      (String.match?(line, ~r/^(rescue|catch)\b/) and
         not String.match?(line, ~r/^(rescue|catch)\b.*\b(in|->)\b.*[A-Z]/))
  end
end
