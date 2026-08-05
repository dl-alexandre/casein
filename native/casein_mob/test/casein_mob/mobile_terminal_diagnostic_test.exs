defmodule CaseinMob.MobileTerminalDiagnosticTest do
  use ExUnit.Case, async: true

  alias CaseinMob.MobileTerminalDiagnostic

  test "records only allowlisted stages with bounded duplicate counters" do
    diagnostic =
      MobileTerminalDiagnostic.new()
      |> MobileTerminalDiagnostic.record(:control_requested)
      |> MobileTerminalDiagnostic.record(:control_requested)
      |> MobileTerminalDiagnostic.record(:child_join_requested)

    assert MobileTerminalDiagnostic.public(diagnostic) == %{
             stage: :child_join_requested,
             counts: %{watch_started: 1, control_requested: 2, child_join_requested: 1}
           }

    saturated =
      Enum.reduce(1..300, diagnostic, fn _, acc ->
        MobileTerminalDiagnostic.record(acc, :status_delivered)
      end)

    assert MobileTerminalDiagnostic.public(saturated).counts.status_delivered == 255
  end

  test "unknown values never become stages or reflected output" do
    canary = "never-reflect-this-secret"
    diagnostic = MobileTerminalDiagnostic.record(MobileTerminalDiagnostic.new(), canary)

    assert MobileTerminalDiagnostic.public(diagnostic).stage == :watch_started
    refute inspect(MobileTerminalDiagnostic.public(diagnostic)) =~ canary
    refute MobileTerminalDiagnostic.valid_public?(%{stage: canary, counts: %{}})
  end

  test "a new diagnostic resets prior connection counters" do
    old =
      MobileTerminalDiagnostic.new()
      |> MobileTerminalDiagnostic.record(:control_requested)
      |> MobileTerminalDiagnostic.record(:baseline_rejected)

    fresh = MobileTerminalDiagnostic.reset(:control_requested)

    assert old.counts.control_requested == 1
    assert fresh == %{stage: :control_requested, counts: %{control_requested: 1}}
  end
end
