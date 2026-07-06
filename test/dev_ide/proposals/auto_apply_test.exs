defmodule DevIDE.Proposals.AutoApplyTest do
  # Exercises maybe_auto_apply/3 directly (the pure gate-and-apply logic) —
  # watch/4's polling loop is a thin Task.Supervisor wrapper around
  # Agents.Run.state/1, already covered for the state-machine itself by
  # test/dev_ide/agents/run_test.exs. Real git-repo fixtures, same pattern as
  # test/dev_ide/proposal_apply_test.exs.
  use ExUnit.Case, async: false

  alias DevIDE.{Audit, Workspaces}
  alias DevIDE.Proposals.AutoApply
  alias DevIDE.Workspaces.State.MemoryAdapter

  @proposal_dir ".opencode/proposals"

  setup do
    root = Path.join(System.tmp_dir!(), "auto-apply-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, @proposal_dir))

    git!(root, ["init", "--initial-branch=main"])
    git!(root, ["config", "user.email", "t@t"])
    git!(root, ["config", "user.name", "t"])

    lines = Enum.map(1..40, &"line #{&1}")
    File.write!(Path.join(root, "a.txt"), Enum.join(lines, "\n") <> "\n")
    git!(root, ["add", "a.txt"])
    git!(root, ["commit", "-m", "init"])

    MemoryAdapter.clear()
    prev_overrides = Application.get_env(:dev_ide, :workspace_modes)
    prev_enabled = Application.get_env(:dev_ide, AutoApply)
    Application.put_env(:dev_ide, :workspace_modes, %{root => :manual})
    Audit.clear()

    on_exit(fn ->
      File.rm_rf!(root)
      MemoryAdapter.clear()

      case prev_overrides do
        nil -> Application.delete_env(:dev_ide, :workspace_modes)
        v -> Application.put_env(:dev_ide, :workspace_modes, v)
      end

      case prev_enabled do
        nil -> Application.delete_env(:dev_ide, AutoApply)
        v -> Application.put_env(:dev_ide, AutoApply, v)
      end
    end)

    {:ok, root: root}
  end

  defp enable!, do: Application.put_env(:dev_ide, AutoApply, enabled: true)

  defp unlock!(root),
    do: Workspaces.grant_agent_write_unlock(root, DateTime.add(DateTime.utc_now(), 3600), "alice")

  defp run_ctx(run_id, overrides \\ %{}) do
    Map.merge(
      %{run_id: run_id, command_id: "test-cmd", status: :succeeded, output_kind: :proposal},
      overrides
    )
  end

  defmodule FakeRun do
    @moduledoc false
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:state, _from, state), do: {:reply, state, state}
  end

  test "watch hands the causality snapshot to the watcher task", %{root: root} do
    # Auto-apply left disabled: the watcher's skip event is the outcome probe.
    :ok = Audit.subscribe(root)

    {:ok, run_pid} =
      FakeRun.start_link(%{status: :succeeded, output_kind: :proposal, started_at: nil})

    cid =
      DevIDE.Signals.Context.with_new(fn ->
        {:ok, _task} = AutoApply.watch(root, root, run_pid, %{run_id: "r-ctx", command_id: "c"})
        DevIDE.Signals.Context.current().trace_id
      end)

    assert_receive {:audit_event, %{action: "proposals.auto_apply_skipped", metadata: metadata}},
                   2_000

    assert metadata["correlation_id"] == cid
  end

  test "non-succeeded or non-proposal runs are a silent no-op", %{root: root} do
    enable!()
    unlock!(root)

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1", %{status: :failed}))

    assert :ok =
             AutoApply.maybe_auto_apply(root, root, run_ctx("r2", %{output_kind: :diagnostic}))

    assert Audit.recent_for(root, 10) == []
  end

  test "disabled kill switch skips and audits, touches no files", %{root: root} do
    unlock!(root)
    write_proposal(root, "r1", edit(root, "a.txt", 2, "line 2 EDITED"))

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1"))
    refute File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"

    [event] = Audit.recent_for(root, 5)
    assert event.action == "proposals.auto_apply_skipped"
    assert event.reason == :auto_apply_disabled
  end

  test "no active unlock denies via Policy and audits the authorize decision", %{root: root} do
    enable!()
    write_proposal(root, "r1", edit(root, "a.txt", 2, "line 2 EDITED"))

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1"))
    refute File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"

    # Denials always record under "policy.blocked" (Audit.emit_decision/2's
    # convention — see workspace:set_mode's gate/3 path for the same shape).
    [event] = Audit.recent_for(root, 5)
    assert event.action == "policy.blocked"
    assert event.decision == :deny
    assert event.reason == :agent_write_locked
  end

  test "missing proposal file skips with :invalid_proposal", %{root: root} do
    enable!()
    unlock!(root)

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("no-such-run"))

    [_authorize, skip] = Audit.recent_for(root, 5) |> Enum.reverse()
    assert skip.action == "proposals.auto_apply_skipped"
    assert skip.reason == :invalid_proposal
  end

  test "non-clean risk skips without applying", %{root: root} do
    enable!()
    unlock!(root)
    write_proposal(root, "r1", edit(root, "a.txt", 2, "line 2 EDITED"))
    # Dirty working tree overlapping the same hunk -> :conflict risk.
    File.write!(
      Path.join(root, "a.txt"),
      replace_line(File.read!(Path.join(root, "a.txt")), 3, "line 3 DIRTY")
    )

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1"))

    events = Audit.recent_for(root, 5)
    skip = Enum.find(events, &(&1.action == "proposals.auto_apply_skipped"))
    assert skip.reason == :analysis_risk
    refute File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"
  end

  test "a diff touching test/ is always skipped, even though risk is clean", %{root: root} do
    enable!()
    unlock!(root)
    File.mkdir_p!(Path.join(root, "test"))
    File.write!(Path.join(root, "test/foo_test.exs"), "defmodule FooTest do\nend\n")
    git!(root, ["add", "test/foo_test.exs"])
    git!(root, ["commit", "-m", "add test file"])

    diff = edit(root, "test/foo_test.exs", 1, "defmodule FooTest do # tampered")
    write_proposal(root, "r1", diff)

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1"))

    events = Audit.recent_for(root, 5)
    skip = Enum.find(events, &(&1.action == "proposals.auto_apply_skipped"))
    assert skip.reason == :touches_test_files
    refute File.read!(Path.join(root, "test/foo_test.exs")) =~ "tampered"
  end

  test "a clean proposal from an unlocked workspace auto-applies and records both events", %{
    root: root
  } do
    enable!()
    unlock!(root)
    write_proposal(root, "r1", edit(root, "a.txt", 2, "line 2 EDITED"))

    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1"))
    assert File.read!(Path.join(root, "a.txt")) =~ "line 2 EDITED"

    events = Audit.recent_for(root, 10)
    applied = Enum.find(events, &(&1.action == "proposals.auto_applied"))
    assert applied.decision == :allow
    assert applied.metadata["risk"] == "clean"
    assert applied.metadata["unlock_granted_by"] == "alice"

    approval = Enum.find(events, &(&1.action == "run.approval_granted"))
    assert approval.metadata["auto"] in [true, "true"]
  end

  test "a git-apply failure is recorded as proposals.auto_apply_failed, no files touched", %{
    root: root
  } do
    enable!()
    unlock!(root)
    diff = edit(root, "a.txt", 2, "line 2 EDITED")

    # Corrupt the context so `git apply --check` rejects it outright (still :clean risk vs an untouched tree).
    corrupted = String.replace(diff, "line 1", "line 1 STALE-CONTEXT")
    write_proposal(root, "r1", corrupted)

    before = File.read!(Path.join(root, "a.txt"))
    assert :ok = AutoApply.maybe_auto_apply(root, root, run_ctx("r1"))
    assert File.read!(Path.join(root, "a.txt")) == before

    events = Audit.recent_for(root, 10)
    failed = Enum.find(events, &(&1.action == "proposals.auto_apply_failed"))
    assert failed.decision == :deny
  end

  ## Helpers

  defp git!(root, args) do
    {out, 0} = System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
    out
  end

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

  defp write_proposal(root, run_id, diff) do
    File.write!(Path.join([root, @proposal_dir, "#{run_id}.diff"]), diff)
  end
end
