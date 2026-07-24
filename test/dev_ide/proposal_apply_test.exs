defmodule Casein.ProposalApplyTest do
  # ProposalApply is the sanctioned write path for the (otherwise read-only)
  # Proposals subsystem — see test/dev_ide/proposals_no_apply_test.exs. These
  # tests exercise real git-repo fixtures (pattern:
  # test/dev_ide/git/local_adapter_test.exs) rather than stubs, since the
  # atomicity guarantee is a property of the real `git apply` shell-out.
  use ExUnit.Case, async: false

  alias Casein.{Audit, ProposalApply}

  @proposal_dir ".opencode/proposals"

  setup do
    root = Path.join(System.tmp_dir!(), "proposal-apply-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, @proposal_dir))

    git!(root, ["init", "--initial-branch=main"])
    git!(root, ["config", "user.email", "t@t"])
    git!(root, ["config", "user.name", "t"])

    lines = Enum.map(1..40, &"line #{&1}")
    File.write!(Path.join(root, "a.txt"), Enum.join(lines, "\n") <> "\n")
    git!(root, ["add", "a.txt"])
    git!(root, ["commit", "-m", "init"])

    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)
    Application.put_env(:dev_ide, :workspace_modes, %{root => :manual})
    Audit.clear()

    on_exit(fn ->
      File.rm_rf!(root)

      case prev_overrides do
        nil -> Application.delete_env(:dev_ide, :workspace_modes)
        v -> Application.put_env(:dev_ide, :workspace_modes, v)
      end
    end)

    {:ok, root: root, ctx: operator_ctx(root)}
  end

  test "clean apply writes files and emits proposal.applied", %{root: root, ctx: ctx} do
    write_proposal(root, "clean.diff", edit(root, "a.txt", 2, "line 2 EDITED"))

    assert {:ok, %{applied_files: ["a.txt"], risk: :clean}} =
             ProposalApply.apply(root, "#{@proposal_dir}/clean.diff", ctx)

    assert File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"

    # Two rows per successful apply, same shape as workspace:set_mode: the
    # gate-style policy-decision event, plus the domain mutation event.
    events = Audit.recent_for(root, 5)
    assert Enum.any?(events, &(&1.action == "apply_proposal" and &1.decision == :allow))

    applied = Enum.find(events, &(&1.action == "proposal.applied"))
    assert applied.decision == :allow
    assert applied.metadata["risk"] == "clean"
    assert applied.metadata["files"] == ["a.txt"]
  end

  test "overlap requires confirm_overlap before applying", %{root: root, ctx: ctx} do
    write_proposal(root, "overlap.diff", edit(root, "a.txt", 2, "line 2 EDITED"))
    # Uncommitted workspace change far enough away that hunks don't overlap.
    File.write!(
      Path.join(root, "a.txt"),
      replace_line(File.read!(Path.join(root, "a.txt")), 30, "line 30 DIRTY")
    )

    assert {:error, {:confirmation_required, analysis}} =
             ProposalApply.apply(root, "#{@proposal_dir}/overlap.diff", ctx)

    assert analysis.risk == :overlap
    refute File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"

    assert {:ok, %{risk: :overlap}} =
             ProposalApply.apply(root, "#{@proposal_dir}/overlap.diff", ctx,
               confirm_overlap: true
             )

    assert File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"
    assert File.read!(Path.join(root, "a.txt")) =~ "line 30 DIRTY"
  end

  test "conflict is blocked unconditionally, even with confirm_overlap: true", %{
    root: root,
    ctx: ctx
  } do
    write_proposal(root, "conflict.diff", edit(root, "a.txt", 2, "line 2 EDITED"))
    # Uncommitted workspace change overlapping the same hunk range.
    File.write!(
      Path.join(root, "a.txt"),
      replace_line(File.read!(Path.join(root, "a.txt")), 3, "line 3 DIRTY")
    )

    before = File.read!(Path.join(root, "a.txt"))

    assert {:error, {:conflict, analysis}} =
             ProposalApply.apply(root, "#{@proposal_dir}/conflict.diff", ctx)

    assert analysis.risk == :conflict

    assert {:error, {:conflict, _}} =
             ProposalApply.apply(root, "#{@proposal_dir}/conflict.diff", ctx,
               confirm_overlap: true
             )

    assert File.read!(Path.join(root, "a.txt")) == before
  end

  test "policy deny touches zero files", %{root: root} do
    before = File.read!(Path.join(root, "a.txt"))
    write_proposal(root, "denied.diff", edit(root, "a.txt", 2, "line 2 EDITED"))

    non_operator_ctx = %{workspace_id: root}

    assert {:error, {:policy, decision}} =
             ProposalApply.apply(root, "#{@proposal_dir}/denied.diff", non_operator_ctx)

    assert decision.reason == :forbidden
    assert File.read!(Path.join(root, "a.txt")) == before
  end

  test "a multi-file diff with one mismatched hunk leaves all files unchanged (atomicity)", %{
    root: root,
    ctx: ctx
  } do
    File.write!(Path.join(root, "b.txt"), "b line 1\nb line 2\n")
    git!(root, ["add", "b.txt"])
    git!(root, ["commit", "-m", "add b"])

    good = edit(root, "a.txt", 2, "line 2 EDITED")
    bad = edit(root, "b.txt", 1, "b line 1 EDITED")
    # Corrupt b.txt's diff so its context no longer matches the working tree,
    # forcing `git apply --check` to fail for the whole (multi-file) patch.
    corrupted_bad = String.replace(bad, "b line 2", "b line 2 STALE-CONTEXT")
    combined = good <> corrupted_bad

    write_proposal(root, "multi.diff", combined)

    assert {:error, {:git_error, _}} =
             ProposalApply.apply(root, "#{@proposal_dir}/multi.diff", ctx)

    refute File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"
    assert File.read!(Path.join(root, "b.txt")) == "b line 1\nb line 2\n"
  end

  test "truncated proposals are refused without invoking git", %{root: root, ctx: ctx} do
    huge_comment = "# " <> String.duplicate("x", 300 * 1024) <> "\n"
    diff = edit(root, "a.txt", 2, "line 2 EDITED")
    write_proposal(root, "huge.diff", huge_comment <> diff)

    assert {:error, {:too_large_to_apply, _size}} =
             ProposalApply.apply(root, "#{@proposal_dir}/huge.diff", ctx)

    refute File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"
  end

  ## Helpers

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    out
  end

  # Edits `rel` at `line_no` (1-indexed) to `new_line`, captures the `git
  # diff`, then reverts the working tree — returns the raw diff text.
  defp edit(root, rel, line_no, new_line) do
    path = Path.join(root, rel)
    File.write!(path, replace_line(File.read!(path), line_no, new_line))
    diff = git!(root, ["diff", "--no-color", "--", rel])
    git!(root, ["checkout", "--", rel])
    diff
  end

  defp replace_line(content, line_no, new_line) do
    content
    |> String.split("\n")
    |> List.update_at(line_no - 1, fn _ -> new_line end)
    |> Enum.join("\n")
  end

  defp write_proposal(root, name, diff) do
    File.write!(Path.join([root, @proposal_dir, name]), diff)
  end

  defp operator_ctx(root) do
    %{workspace_id: root, workspace_user: "alice", actor_username: "alice", actor_id: "alice"}
  end
end
