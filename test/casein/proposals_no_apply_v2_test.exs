defmodule Casein.ProposalsNoApplyV2Test do
  @moduledoc """
  Boundary guard for M12: extending the analyzer must not introduce a write
  or apply path. The original M9 guard catches the obvious smells; this one
  asserts the new analyzer modules in particular. These modules are also
  relied upon (read-only) by `Casein.ProposalApply`'s risk gating — see
  `Casein.ProposalsNoApplyTest`.
  """
  use Casein.TestCase, async: true

  @sources [
    "lib/casein/proposals/conflict_analyzer.ex",
    "lib/casein/proposals/analysis.ex",
    "lib/casein/proposals/hunk.ex",
    "lib/casein/proposals/unified_diff.ex"
  ]

  test "no analyzer source contains a write or apply path" do
    for rel <- @sources do
      src = File.read!(Path.expand(rel, File.cwd!()))

      refute src =~ ~r/File\.(write|cp|rename|rm)\b/, "write call found in #{rel}"
      refute src =~ ~r/git\s+apply/, "git apply token in #{rel}"
      refute src =~ ~r/System\.cmd\(["']patch/, "patch CLI in #{rel}"
      refute src =~ ~r/apply_patch/, "apply_patch token in #{rel}"
      refute src =~ ~r/"proposal:apply"/, "apply event in #{rel}"
    end
  end

  test "Analysis struct has no apply or write fields" do
    fields = %Casein.Proposals.Analysis{} |> Map.from_struct() |> Map.keys() |> MapSet.new()

    for forbidden <- ~w(apply applied apply_path apply_result write_path)a do
      refute MapSet.member?(fields, forbidden), "Analysis exposes #{forbidden}"
    end
  end

  test "ProposalApply reuses Proposals.analyze/2 instead of reimplementing conflict detection" do
    src = File.read!(Path.expand("lib/casein/proposal_apply.ex", File.cwd!()))
    assert src =~ "Proposals.analyze"
  end
end
