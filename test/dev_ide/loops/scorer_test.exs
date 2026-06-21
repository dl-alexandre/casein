defmodule DevIDE.Loops.ScorerTest do
  use ExUnit.Case, async: true

  alias DevIDE.Loops.Scorer

  defp eval(overrides \\ %{}) do
    Map.merge(
      %{
        compile_ok: true,
        test_pass: false,
        holdout_pass: false,
        touched_test_files: false,
        added_rescue: false,
        new_failures: []
      },
      Map.new(overrides)
    )
  end

  describe "score/1" do
    test "compile failure is a hard gate -> 0 regardless of anything else" do
      assert {0, breakdown} =
               Scorer.score(eval(%{compile_ok: false, test_pass: true, holdout_pass: true}))

      assert breakdown =~ "hard gate"
    end

    test "a clean, non-passing compile scores the +20 floor" do
      assert {20, breakdown} = Scorer.score(eval())
      assert breakdown =~ "+20 compiles"
    end

    test "passing the frozen target and held-out reaches the full score" do
      assert {100, _} = Scorer.score(eval(%{test_pass: true, holdout_pass: true}))
    end

    test "editing test files is penalized below the non-passing floor" do
      {gamed, _} =
        Scorer.score(eval(%{test_pass: true, holdout_pass: true, touched_test_files: true}))

      {honest_floor, _} = Scorer.score(eval())
      assert gamed == 60
      assert gamed < 100
      # the penalty exists so gaming can't out-score an in-progress honest attempt by much
      assert gamed - honest_floor == 40
    end

    test "a bare rescue is penalized" do
      assert {85, breakdown} =
               Scorer.score(eval(%{test_pass: true, holdout_pass: true, added_rescue: true}))

      assert breakdown =~ "PENALTY"
    end

    test "held-out regressions surface in the breakdown" do
      {_score, breakdown} =
        Scorer.score(eval(%{test_pass: true, new_failures: ["test/x_test.exs:9"]}))

      assert breakdown =~ "held-out regressed"
      assert breakdown =~ "x_test.exs:9"
    end
  end

  describe "solved?/2" do
    test "true only when target + held-out pass, tests untouched, and verdict clears it" do
      e = eval(%{test_pass: true, holdout_pass: true})
      assert Scorer.solved?(e, %{legit: true, gamed: false})
    end

    test "a high score that gamed the metric is NOT solved" do
      e = eval(%{test_pass: true, holdout_pass: true, touched_test_files: true})
      refute Scorer.solved?(e, %{legit: false, gamed: true})
    end

    test "passing tests but a non-legit verdict is NOT solved" do
      e = eval(%{test_pass: true, holdout_pass: true})
      refute Scorer.solved?(e, %{legit: false, gamed: false})
    end

    test "a missing verdict is treated as not-yet-cleared" do
      e = eval(%{test_pass: true, holdout_pass: true})
      refute Scorer.solved?(e, nil)
    end
  end
end
