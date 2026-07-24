defmodule Casein.ProposalsNoApplyTest do
  @moduledoc """
  Boundary guard for M9. The read-only Proposals subsystem (discover/parse)
  must never itself gain a write/apply path — the write path lives
  exclusively in `Casein.ProposalApply`, gated by
  `Casein.Policy.can_apply_proposal?/1`. This guard doesn't forbid applying
  proposals (see `Casein.ProposalApplyTest`); it forbids the *read-only*
  modules listed below from ever doing it themselves.
  """
  use Casein.TestCase, async: true

  alias Casein.Policy

  @forbidden_callbacks ~w(apply apply_patch write_file mutate_workspace grant_write)a

  @read_only_sources [
    "lib/dev_ide/proposals.ex",
    "lib/dev_ide/proposals/adapter.ex",
    "lib/dev_ide/proposals/local_adapter.ex",
    "lib/dev_ide/proposals/unified_diff.ex",
    "lib/dev_ide/proposals/proposal.ex"
  ]

  test "Proposals behaviour exposes only discover and parse" do
    callbacks =
      Casein.Proposals.Adapter.behaviour_info(:callbacks)
      |> Enum.map(fn {n, _} -> n end)
      |> Enum.sort()

    assert callbacks == [:discover, :parse]
  end

  test "Proposals behaviour does not expose forbidden callbacks" do
    set =
      Casein.Proposals.Adapter.behaviour_info(:callbacks)
      |> Enum.map(fn {n, _} -> n end)
      |> MapSet.new()

    for cb <- @forbidden_callbacks do
      refute MapSet.member?(set, cb), "forbidden callback #{cb}"
    end
  end

  test "no read-only proposals source writes files or applies patches" do
    for rel <- @read_only_sources do
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

  test "proposal:* events live in ProposalPanelComponent, gated and never applied in Show" do
    show_src =
      File.read!(Path.expand("lib/dev_ide_web/live/workspace_live/show.ex", File.cwd!()))

    refute show_src =~ ~r/handle_event\("proposal:/,
           "show.ex must not handle proposal:* events; they target ProposalPanelComponent"

    refute show_src =~ ~r/File\.(write|cp|rename|rm)\b/, "write-style call found in show.ex"
    refute show_src =~ ~r/git\s+apply/, "git apply found in show.ex"
    refute show_src =~ ~r/System\.cmd\(["']patch/, "patch CLI found in show.ex"

    component_src =
      File.read!(
        Path.expand(
          "lib/dev_ide_web/live/workspace_live/proposal_panel_component.ex",
          File.cwd!()
        )
      )

    assert component_src =~ "ProposalApply.apply",
           "the component must apply via Casein.ProposalApply, never Casein.Proposals"

    # Component events bypass Show's authz hook, so every handler must gate.
    handler_count =
      component_src |> String.split(~s(def handle_event(")) |> length() |> Kernel.-(1)

    gate_count =
      component_src |> String.split("PanelGate.gate_event(") |> length() |> Kernel.-(1)

    assert handler_count > 0

    assert gate_count >= handler_count,
           "every ProposalPanelComponent handle_event must run PanelGate.gate_event"

    refute component_src =~ ~r/File\.(write|cp|rename|rm)\b/,
           "write-style call found in proposal_panel_component.ex"
  end

  test "the write path lives only in Casein.ProposalApply, gated by Policy" do
    src = File.read!(Path.expand("lib/dev_ide/proposal_apply.ex", File.cwd!()))
    assert src =~ "Policy.can_apply_proposal?", "ProposalApply must funnel through Policy"

    git_adapter_src =
      File.read!(Path.expand("lib/dev_ide/proposal_apply/git_adapter.ex", File.cwd!()))

    assert git_adapter_src =~ ~r/"apply"/,
           "git-apply shell-out must live in ProposalApply.GitAdapter"
  end

  test "can_apply_proposal? is no longer a blanket :not_implemented stub" do
    decision = Policy.can_apply_proposal?(%{workspace_id: "guard-ws"})
    refute decision.reason == :not_implemented
  end
end
