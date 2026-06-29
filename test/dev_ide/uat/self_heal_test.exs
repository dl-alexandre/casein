defmodule DevIDE.UAT.SelfHealTest do
  use ExUnit.Case, async: true

  alias DevIDE.UAT.{FakeGit, Run, SelfHeal, Step, Trace}

  defp trace(selector) do
    %Trace{
      id: "s",
      criterion: "c",
      steps: [%Step{kind: :click, match: %{"selector" => selector}}]
    }
  end

  test "a regression classification reports the run and proposes nothing" do
    run = %Run{id: 7, outcome: :drift}

    assert {:regression, ^run} =
             SelfHeal.handle_drift("s", trace("a"), run, classifier: fn _ -> :regression end)

    assert FakeGit.last() == nil
  end

  test "a ui_changed classification re-authors and opens a proposal PR" do
    run = %Run{id: 8, outcome: :drift}

    assert {:proposed, "pr://fake"} =
             SelfHeal.handle_drift("s", trace("a"), run,
               classifier: fn _ -> :ui_changed end,
               reauthor: fn -> {:ok, %{trace: trace("b")}} end,
               git: FakeGit
             )

    assert FakeGit.last().branch == "uat/reheal-s"
  end

  test "an unexpected classification is an error" do
    run = %Run{id: 9, outcome: :drift}

    assert {:error, {:bad_classification, :maybe}} =
             SelfHeal.handle_drift("s", trace("a"), run, classifier: fn _ -> :maybe end)
  end
end
