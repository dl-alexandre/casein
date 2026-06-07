defmodule DevIDE.ProposalsNoApplyTest do
  @moduledoc """
  Boundary guard for M9. The Proposals subsystem must not gain any
  apply/write callbacks, and no source path may write files based on a
  proposal's content.
  """
  use ExUnit.Case, async: true

  @forbidden_callbacks ~w(apply apply_patch write_file mutate_workspace grant_write)a

  @sources [
    "lib/dev_ide/proposals.ex",
    "lib/dev_ide/proposals/adapter.ex",
    "lib/dev_ide/proposals/local_adapter.ex",
    "lib/dev_ide/proposals/unified_diff.ex",
    "lib/dev_ide/proposals/proposal.ex",
    "lib/dev_ide_web/live/workspace_live/show.ex"
  ]

  test "Proposals behaviour exposes only discover and parse" do
    callbacks =
      DevIDE.Proposals.Adapter.behaviour_info(:callbacks)
      |> Enum.map(fn {n, _} -> n end)
      |> Enum.sort()

    assert callbacks == [:discover, :parse]
  end

  test "Proposals behaviour does not expose forbidden callbacks" do
    set =
      DevIDE.Proposals.Adapter.behaviour_info(:callbacks)
      |> Enum.map(fn {n, _} -> n end)
      |> MapSet.new()

    for cb <- @forbidden_callbacks do
      refute MapSet.member?(set, cb), "forbidden callback #{cb}"
    end
  end

  test "no proposals source writes files or applies patches" do
    for rel <- @sources do
      src = File.read!(Path.expand(rel, File.cwd!()))

      # No write paths: File.write/cp/rename, git apply, patch CLI, etc.
      refute src =~ ~r/File\.(write|cp|rename|rm)\b(?!.*\.tmp\.)/,
             "write-style call found in #{rel}"

      refute src =~ ~r/git\s+apply/, "git apply found in #{rel}"
      refute src =~ ~r/System\.cmd\(["']patch/, "patch CLI found in #{rel}"
      refute src =~ ~r/apply_patch/, "apply_patch token in #{rel}"

      # Phoenix LiveView event names that would imply mutation
      refute src =~ ~r/"proposal:apply"/, "apply event found in #{rel}"
    end
  end
end
