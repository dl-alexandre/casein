defmodule DevIDE.Loops.Scorer do
  @moduledoc """
  The fitness function — pure, deterministic, and the anti-gaming core of the
  loop.

  This is the coding equivalent of a quant strategy's score (Sharpe, drawdown):
  it collapses an objective evaluation into a single number the loop can climb,
  with a hard gate and explicit penalties so the generator can't win by gaming
  the metric.

    * compile is a HARD gate — fail it and the score is 0, full stop
    * +20 compiles
    * +50 frozen target test passes
    * +30 held-out: no new failures vs the baseline
    * −40 PENALTY: the diff edited a file under `test/`
    * −15 PENALTY: the diff added a bare `rescue` / swallowed an error

  `solved?/2` is deliberately stricter than a high score: a fix only counts if
  it passes the frozen target AND the held-out set, did NOT touch tests, and
  survives the integrity verdict. A high-scoring-but-gamed attempt is rejected —
  the lesson of the "flawless backtest that bled live".
  """

  @type eval :: %{
          optional(:compile_ok) => boolean(),
          optional(:test_pass) => boolean(),
          optional(:holdout_pass) => boolean(),
          optional(:touched_test_files) => boolean(),
          optional(:added_rescue) => boolean(),
          optional(:new_failures) => [String.t()]
        }

  @type verdict :: %{
          optional(:legit) => boolean(),
          optional(:gamed) => boolean(),
          optional(:reason) => String.t()
        }

  @doc """
  Composite score + human-readable breakdown for an evaluation.

  Returns `{score :: integer, breakdown :: String.t()}`.
  """
  @spec score(eval()) :: {integer(), String.t()}
  def score(eval) when is_map(eval) do
    if truthy(eval, :compile_ok) do
      {value, parts} =
        {20, ["+20 compiles"]}
        |> add(
          truthy(eval, :test_pass),
          50,
          "+50 frozen target passes",
          "+0 frozen target still fails"
        )
        |> add(
          truthy(eval, :holdout_pass),
          30,
          "+30 held-out: no new failures",
          "+0 held-out regressed: " <> inspect(Map.get(eval, :new_failures, []))
        )
        |> penalize(truthy(eval, :touched_test_files), 40, "-40 PENALTY: diff edits test files")
        |> penalize(truthy(eval, :added_rescue), 15, "-15 PENALTY: bare rescue / swallowed error")

      {value, Enum.join(parts, ", ")}
    else
      {0, "compile FAILED (hard gate -> 0)"}
    end
  end

  @doc """
  Whether an attempt genuinely solved the target: passed the frozen target and
  the held-out set, did not edit tests, and the integrity verdict cleared it
  (legit and not gamed). A nil/absent verdict is treated as not-yet-cleared.
  """
  @spec solved?(eval(), verdict() | nil) :: boolean()
  def solved?(eval, verdict) when is_map(eval) do
    truthy(eval, :test_pass) and
      truthy(eval, :holdout_pass) and
      not truthy(eval, :touched_test_files) and
      truthy(verdict || %{}, :legit) and
      not truthy(verdict || %{}, :gamed)
  end

  defp add({value, parts}, true, points, on, _off), do: {value + points, parts ++ [on]}
  defp add({value, parts}, false, _points, _on, off), do: {value, parts ++ [off]}

  defp penalize({value, parts}, true, points, label), do: {value - points, parts ++ [label]}
  defp penalize({value, parts}, false, _points, _label), do: {value, parts}

  defp truthy(map, key), do: Map.get(map, key) == true
end
