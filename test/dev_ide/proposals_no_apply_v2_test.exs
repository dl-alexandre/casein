defmodule DevIDE.ProposalsNoApplyV2Test do
  @moduledoc """
  Boundary guard for M12: extending the analyzer must not introduce a write
  or apply path. The original M9 guard catches the obvious smells; this one
  asserts the new analyzer modules in particular.
  """
  use DevIDE.TestCase, async: true

  @sources [
    "lib/dev_ide/proposals/conflict_analyzer.ex",
    "lib/dev_ide/proposals/analysis.ex",
    "lib/dev_ide/proposals/hunk.ex",
    "lib/dev_ide/proposals/unified_diff.ex"
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
    fields = %DevIDE.Proposals.Analysis{} |> Map.from_struct() |> Map.keys() |> MapSet.new()

    for forbidden <- ~w(apply applied apply_path apply_result write_path)a do
      refute MapSet.member?(fields, forbidden), "Analysis exposes #{forbidden}"
    end
  end
end
