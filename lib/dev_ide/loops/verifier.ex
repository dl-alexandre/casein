defmodule DevIDE.Loops.Verifier do
  @moduledoc """
  The integrity seam — the adversarial gate that decides whether a passing
  attempt is a genuine fix or a gamed one.

  In the Workflow prototype this was a separate LLM judge prompted to refute by
  default. In-process, `DevIDE.Loops.Verifier.Heuristic` provides a deterministic
  baseline that catches the mechanical gaming the sandbox already detects
  (editing tests, swallowing errors). Wire an LLM-backed verifier for the
  judgement calls a heuristic can't make (e.g. hardcoding the expected value,
  sidestepping rather than fixing the defect).
  """

  @type eval :: DevIDE.Loops.Sandbox.eval()

  @type verdict :: %{legit: boolean(), gamed: boolean(), reason: String.t()}

  @callback verify(diff :: String.t(), eval(), context :: map()) :: {:ok, verdict()}

  @doc "The configured verifier module (defaults to the heuristic gate)."
  @spec impl() :: module()
  def impl do
    Application.get_env(:dev_ide, DevIDE.Loops, [])[:verifier] || DevIDE.Loops.Verifier.Heuristic
  end
end

defmodule DevIDE.Loops.Verifier.Heuristic do
  @moduledoc """
  Deterministic, conservative integrity gate: an attempt is `gamed` if the diff
  edited tests or added a bare rescue, and `legit` only if it cleanly passed the
  frozen target and the held-out set without gaming. Defaults toward
  not-legit when signals are ambiguous (refute-by-default, like the prototype).
  """
  @behaviour DevIDE.Loops.Verifier

  @impl true
  def verify(_diff, eval, _context) do
    gamed = truthy(eval, :touched_test_files) or truthy(eval, :added_rescue)

    legit =
      not gamed and truthy(eval, :test_pass) and truthy(eval, :holdout_pass) and
        truthy(eval, :compile_ok)

    {:ok, %{legit: legit, gamed: gamed, reason: reason(gamed, legit, eval)}}
  end

  defp reason(true, _legit, eval) do
    cond do
      truthy(eval, :touched_test_files) -> "gamed: diff edits files under test/"
      truthy(eval, :added_rescue) -> "gamed: diff adds a bare rescue that swallows errors"
      true -> "gamed"
    end
  end

  defp reason(false, true, _eval), do: "legit: clean pass of frozen target + held-out, no gaming"

  defp reason(false, false, eval) do
    cond do
      not truthy(eval, :compile_ok) -> "not legit: does not compile"
      not truthy(eval, :test_pass) -> "not legit: frozen target still fails"
      not truthy(eval, :holdout_pass) -> "not legit: introduced new failures"
      true -> "not legit"
    end
  end

  defp truthy(map, key), do: Map.get(map, key) == true
end
