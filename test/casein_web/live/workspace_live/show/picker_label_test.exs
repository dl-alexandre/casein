defmodule CaseinWeb.WorkspaceLive.Show.PickerLabelTest do
  use ExUnit.Case, async: true

  alias CaseinWeb.WorkspaceLive.Show.PickerLabel

  # #949 constraint: generated ids differ at the END (and often the middle).
  # Head-truncation makes distinct rows look identical. Middle-truncation must
  # keep both ends; human labels must not gain a hole in the middle.

  @b921 "agent-opencode-b921-perf-lifecycle-events-20260813013053"
  @b926 "agent-opencode-b926-db-indexes-20260813013055"
  @casein_noop "CASEIN_886_PS_1786488699_NOOP"
  @worker "worker-s2r2-897-clock-proto"
  @worktree "casein-agent-worktrees/agent-grok-adhoc-20260813013053"
  @grok_a "agent-grok-adhoc-20260813013053"
  @grok_b "agent-grok-adhoc-20260813013055"
  @grok_c "agent-grok-issue-949-picker"

  test "classifies generated ids and leaves human titles alone" do
    assert PickerLabel.generated_id?(@b921)
    assert PickerLabel.generated_id?(@casein_noop)
    assert PickerLabel.generated_id?(@worker)
    assert PickerLabel.generated_id?(@worktree)
    assert PickerLabel.generated_id?("casein_dalexandre-devide_wt-95f482cc")
    refute PickerLabel.generated_id?("Fix the session picker")
    refute PickerLabel.generated_id?("Scratch")
    refute PickerLabel.generated_id?("dalexandre-casein")
  end

  test "middle-truncation keeps both ends of the observed fleet ids" do
    a = PickerLabel.display(@b921)
    b = PickerLabel.display(@b926)
    assert a != b
    assert String.starts_with?(a, "agent-")
    assert String.ends_with?(a, "53")
    assert String.ends_with?(b, "55")
    assert String.contains?(a, "…")
    refute String.contains?(PickerLabel.display("Fix the session picker"), "…")
  end

  test "CASEIN attach ids keep the NOOP tail; worker names keep the task slug" do
    shown = PickerLabel.display(@casein_noop)
    assert String.contains?(shown, "…")
    assert String.ends_with?(shown, "NOOP")

    worker = PickerLabel.display(@worker)
    assert String.contains?(worker, "…")
    assert String.contains?(worker, "proto")
  end

  test "three agent-grok rows stay distinguishable after group shortening" do
    [a, b, c] = PickerLabel.display_group([@grok_a, @grok_b, @grok_c])
    assert a != b
    assert b != c
    assert a != c
    assert String.contains?(a, "…")
    assert String.ends_with?(a, "53")
    assert String.ends_with?(b, "55")
    assert String.contains?(c, "picker")
  end

  test "elides the prefix shared by a group, not a global casein- prefix" do
    [a, b] = PickerLabel.display_group([@b921, @b926])
    assert String.starts_with?(a, "…")
    assert String.starts_with?(b, "…")
    refute String.contains?(a, "agent-opencode-agent-opencode")
    assert a != b
    assert String.ends_with?(a, "53")
    assert String.ends_with?(b, "55")

    lone = PickerLabel.display_group([@b921])
    assert lone == [PickerLabel.display(@b921)]
  end

  test "annotate_group does not change the underlying label" do
    items = [
      %{label: @b921, detail: @worktree},
      %{label: "Fix the picker", detail: ""}
    ]

    [gen, human] = PickerLabel.annotate_group(items)
    assert gen.label == @b921
    assert gen.detail == @worktree
    assert gen.display_label != @b921
    assert String.contains?(gen.display_label, "…")
    assert human.label == "Fix the picker"
    assert human.display_label == "Fix the picker"
  end

  test "short header clamp middle-truncates generated ids at 9" do
    shown = PickerLabel.display(@grok_a, max: 9)
    assert String.length(shown) == 9
    assert String.contains?(shown, "…")
    refute String.starts_with?(shown, "agent-gro") and not String.contains?(shown, "…")
  end
end
