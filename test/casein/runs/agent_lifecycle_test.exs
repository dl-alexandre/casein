defmodule Casein.Runs.AgentLifecycleTest do
  use Casein.TestCase, async: false

  alias Casein.Audit
  alias Casein.Runs.{AgentLifecycle, Ledger}
  alias Casein.Terminals.{AgentState, IssueBinding}

  @ws "ws-agent-lifecycle"
  @session "casein_lifecycle_s1"
  @pane "%7"

  setup do
    Audit.clear()
    AgentLifecycle.clear()
    AgentState.clear()
    IssueBinding.clear_all()
    :ok
  end

  test "opens a Run on first :working and closes on :done" do
    observe(:working, "compiling")
    open = await_open()

    assert open.run_id
    assert open.opened_by == "working"
    assert open.workspace_id == @ws
    assert open.pane_id == @pane

    assert ["run.started"] = actions_for(open.run_id)

    observe(:done, "turn complete")
    await_closed()

    assert ["run.started", "run.succeeded"] = actions_for(open.run_id)

    [summary] = Ledger.recent_runs_for(@ws, 5)
    assert summary.id == open.run_id
    assert summary.status == "succeeded"
    assert summary.command_id == "agent.lifecycle"
  end

  test "first send_command opens when no Run is open (silent-runtime fallback)" do
    AgentLifecycle.note_send_command(%{
      workspace_id: @ws,
      tmux_session: @session,
      pane_id: @pane,
      actor_id: "orchestrator",
      tool: "terminal_send_command",
      message: "mix test",
      source: :send_command
    })

    open = await_open()
    assert open.opened_by == "send_command"
    assert open.actor_id == "orchestrator"
    assert ["run.started"] = actions_for(open.run_id)

    # Second send_command does not start another Run.
    AgentLifecycle.note_send_command(%{
      workspace_id: @ws,
      tmux_session: @session,
      pane_id: @pane,
      actor_id: "orchestrator",
      tool: "terminal_send_command",
      message: "mix format",
      source: :send_command
    })

    flush()
    assert AgentLifecycle.get(@session, @pane).run_id == open.run_id
    assert length(actions_for(open.run_id)) == 1
  end

  test ":blocked emits approval_requested and keeps the Run open" do
    observe(:working, nil)
    open = await_open()

    observe(:blocked, "needs permission")
    flush()

    assert AgentLifecycle.get(@session, @pane)
    assert ["run.started", "run.approval_requested"] = actions_for(open.run_id)

    [summary] = Ledger.recent_runs_for(@ws, 5)
    assert summary.id == open.run_id
    assert summary.status == "approval_requested"
  end

  test "leaving :blocked for :working grants approval without closing" do
    observe(:working, nil)
    open = await_open()
    observe(:blocked, "perm")
    flush()

    observe(:working, "resumed")
    flush()

    assert AgentLifecycle.get(@session, @pane)

    assert ["run.started", "run.approval_requested", "run.approval_granted"] =
             actions_for(open.run_id)
  end

  test ":errored closes as failed; approval_denied if previously blocked" do
    observe(:working, nil)
    open = await_open()
    observe(:blocked, "perm")
    flush()

    observe(:errored, "provider 400")
    await_closed()

    assert [
             "run.started",
             "run.approval_requested",
             "run.approval_denied",
             "run.failed"
           ] = actions_for(open.run_id)
  end

  test ":stalled closes as timed_out (design: prefer close over hang)" do
    observe(:working, nil)
    open = await_open()

    observe(:stalled, nil)
    await_closed()

    assert ["run.started", "run.timed_out"] = actions_for(open.run_id)
  end

  test ":idle after work closes the Run (prefer close over hang)" do
    observe(:working, nil)
    open = await_open()

    observe(:idle, nil)
    await_closed()

    assert ["run.started", "run.succeeded"] = actions_for(open.run_id)
  end

  test "issue binding is an attribute of the Run, not its identity" do
    assert {:ok, _} = IssueBinding.bind(@ws, @session, @pane, 711, title: "design")

    observe(:working, nil)
    open = await_open()
    assert open.issue == 711

    [started | _] = Ledger.timeline_for(@ws, open.run_id)
    assert started.metadata["issue"] == 711
    assert started.metadata["pane"] == @pane
  end

  test "prune_session closes open Runs as abandoned on pane death" do
    observe(:working, nil)
    open = await_open()

    AgentLifecycle.prune_session(@session, [])
    await_closed()

    assert ["run.started", "run.failed"] = actions_for(open.run_id)

    [summary] = Ledger.recent_runs_for(@ws, 5)
    assert summary.status == "failed"
    assert summary.id == open.run_id

    [finished | _] =
      Ledger.timeline_for(@ws, open.run_id)
      |> Enum.filter(&(&1.action == "run.failed"))

    assert finished.metadata["status"] in ["abandoned", :abandoned] or
             finished.metadata["status"] == "abandoned"
  end

  test "AgentState.report transitions feed the lifecycle boundary" do
    :ok = AgentState.report(@ws, @session, @pane, :working, "via AgentState")
    open = await_open()

    :ok = AgentState.report(@ws, @session, @pane, :done, nil)
    await_closed()

    assert ["run.started", "run.succeeded"] = actions_for(open.run_id)
  end

  test "AgentState source has zero Ledger references (design ground truth)" do
    root = File.cwd!()

    for path <- [
          Path.join(root, "lib/casein/terminals/agent_state.ex"),
          Path.join(root, "lib/casein/terminals/agent_state/server.ex")
        ] do
      source = File.read!(path)
      refute source =~ "Runs.Ledger", "#{path} must not reference Runs.Ledger"
      refute source =~ "Ledger.run_", "#{path} must not call Ledger.run_*"
    end

    # Boundary emitter is the only AgentState → Ledger bridge.
    lifecycle = File.read!(Path.join(root, "lib/casein/runs/agent_lifecycle.ex"))
    assert lifecycle =~ "Ledger.run_started"
    assert lifecycle =~ "approval_requested"
  end

  defp observe(state, message) do
    AgentLifecycle.observe_state(%{
      workspace_id: @ws,
      tmux_session: @session,
      pane_id: @pane,
      state: state,
      message: message,
      actor_id: "agent",
      source: :mcp,
      tool: "terminal_report_agent_state"
    })
  end

  defp await_open do
    Enum.find_value(1..50, fn _ ->
      case AgentLifecycle.get(@session, @pane) do
        nil ->
          Process.sleep(5)
          nil

        open ->
          open
      end
    end) || flunk("expected an open Run on #{@session}/#{@pane}")
  end

  defp await_closed do
    Enum.find_value(1..50, fn _ ->
      case AgentLifecycle.get(@session, @pane) do
        nil ->
          true

        _open ->
          Process.sleep(5)
          nil
      end
    end) || flunk("expected Run to close on #{@session}/#{@pane}")
  end

  defp flush do
    # Drain cast mailbox: a no-op call serializes behind pending casts.
    _ = AgentLifecycle.get(@session, @pane)
    :ok
  end

  defp actions_for(run_id) do
    flush()

    @ws
    |> Ledger.timeline_for(run_id)
    |> Enum.map(& &1.action)
  end
end
