defmodule DevIDE.UAT.ProposalTest do
  use ExUnit.Case, async: true

  alias DevIDE.UAT.{FakeGit, Proposal, Step, Trace}

  defp trace(selector) do
    %Trace{
      id: "checkout",
      criterion: "c",
      steps: [%Step{kind: :click, match: %{"selector" => selector}}]
    }
  end

  test "build computes a per-step diff between old and new" do
    p = Proposal.build(trace("a"), trace("b"), %{scenario_id: "checkout", run_id: "1"})
    assert [%{"index" => 0, "old" => old, "new" => new}] = p["step_diff"]
    assert old["match"]["selector"] == "a"
    assert new["match"]["selector"] == "b"
    assert p["reason"] == "ui_changed"
  end

  test "propose publishes a reheal PR through the git seam — no in-place mutation" do
    assert {:ok, "pr://fake"} =
             Proposal.propose(trace("a"), trace("b"), %{scenario_id: "checkout", run_id: "42"},
               git: FakeGit
             )

    call = FakeGit.last()
    assert call.branch == "uat/reheal-checkout"

    paths = Enum.map(call.files, fn {p, _} -> p end)
    assert "priv/uat/checkout/trace.json" in paths
    assert Enum.any?(paths, &String.contains?(&1, "proposals/checkout-42"))

    # The committed trace on disk is untouched — the change rides the PR.
    assert File.read!("priv/uat/checkout/trace.json") =~ "REPLACE_WITH_GIT_SHA"
  end

  test "the new trace content is what the PR would commit" do
    Proposal.propose(trace("a"), trace("b"), %{scenario_id: "checkout", run_id: "7"},
      git: FakeGit
    )

    {_, new_trace_json} =
      Enum.find(FakeGit.last().files, fn {p, _} -> String.ends_with?(p, "checkout/trace.json") end)

    assert new_trace_json =~ "\"selector\": \"b\""
  end
end
