defmodule DevIDE.Operator.SituationServerTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Operator.SituationServer
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Workspace
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.MemoryAdapter

  @app_env ~w(situation_server situation_blocked_too_long_seconds tmux_adapter
              runtimes_adapter agent_worktree_roots)a

  setup do
    prev = Map.new(@app_env, &{&1, Application.get_env(:dev_ide, &1)})

    MemoryAdapter.clear()
    DevIDE.Runtimes.clear()
    Audit.clear()
    Activity.clear()
    AgentState.clear()

    Application.put_env(:dev_ide, :tmux_adapter, DevIDE.Test.FakeTmuxAdapter)
    Application.put_env(:dev_ide, :runtimes_adapter, DevIDE.Runtimes.MemoryAdapter)
    # Point the WorktreeAlarm sweep (spawned by the detector engine) at an
    # empty root so tests never scan the box's real agent worktrees.
    Application.put_env(:dev_ide, :agent_worktree_roots, [
      Path.join(System.tmp_dir!(), "devide-situation-test-empty")
    ])

    on_exit(fn ->
      MemoryAdapter.clear()
      DevIDE.Runtimes.clear()
      Audit.clear()
      Activity.clear()
      AgentState.clear()

      Enum.each(prev, fn
        {key, nil} -> Application.delete_env(:dev_ide, key)
        {key, value} -> Application.put_env(:dev_ide, key, value)
      end)
    end)

    :ok
  end

  defp seed_workspace(ws_id) do
    {:ok, _} =
      State.sync(%Workspace{
        id: ws_id,
        name: ws_id,
        user: "alice",
        branch: "main",
        status: :running,
        path: nil,
        metadata: %{}
      })

    :ok
  end

  defp start_server(ws_id) do
    seed_workspace(ws_id)
    {:ok, pid} = SituationServer.ensure_started(ws_id)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  # The boot rebuild kicks an async worktree sweep whose (empty) result would
  # clobber alarms injected before it lands — wait it out first.
  defp await_boot_sweep(pid, tries \\ 50) do
    state = :sys.get_state(pid)

    cond do
      state.worktree_sweep_ref == nil and state.worktree_swept_at_ms != nil ->
        :ok

      tries == 0 ->
        flunk("boot worktree sweep never finished")

      true ->
        Process.sleep(20)
        await_boot_sweep(pid, tries - 1)
    end
  end

  defp blocked_entry(ago_s, message \\ "waiting on permission") do
    %{
      state: :blocked,
      message: message,
      source: :mcp,
      tool: nil,
      workspace_id: nil,
      transcript_path: nil,
      reported_at: DateTime.add(DateTime.utc_now(), -ago_s, :second)
    }
  end

  test "get_digest cold-builds when the flag is off and starts no server" do
    Application.put_env(:dev_ide, :situation_server, false)
    seed_workspace("ws-sit-cold")

    assert {:ok, digest} = SituationServer.get_digest("ws-sit-cold")
    assert digest.workspace_id == "ws-sit-cold"
    assert SituationServer.whereis("ws-sit-cold") == nil
  end

  test "get_digest with the flag on starts the server once and serves the live digest" do
    Application.put_env(:dev_ide, :situation_server, true)
    seed_workspace("ws-sit-live")

    assert {:ok, digest} = SituationServer.get_digest("ws-sit-live")
    assert digest.workspace_id == "ws-sit-live"

    pid = SituationServer.whereis("ws-sit-live")
    assert is_pid(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    assert {:ok, _} = SituationServer.get_digest("ws-sit-live")
    assert SituationServer.whereis("ws-sit-live") == pid
  end

  test "invalid workspace ids keep the cold error contract" do
    assert {:error, :invalid_workspace_id} = SituationServer.get_digest("")
    assert {:error, :invalid_workspace_id} = SituationServer.get_digest(nil)
  end

  test "agent MCP activity fans into the live digest in place" do
    pid = start_server("ws-sit-act")

    _ =
      Activity.record(%{
        workspace_id: "ws-sit-act",
        source: :terminal_mcp,
        tool: "terminal_capture",
        summary: "session=devide_sit",
        status: :ok
      })

    assert {:ok, digest} = GenServer.call(pid, :get_digest)
    assert [entry | _] = digest.activity.recent
    assert entry.tool == "terminal_capture"
    # Freshness is re-stamped at read time: a just-patched activity section is
    # at most moments stale, never frozen at the last full rebuild.
    assert digest.freshness.activity < 5_000
  end

  test "audit events fan into activity.last_mutation" do
    pid = start_server("ws-sit-audit")

    # Settle past the boot rebuild so any operator.risk_* rows its detector
    # pass announces are already applied before this test's event.
    assert {:ok, _} = GenServer.call(pid, :get_digest)

    Audit.emit!(%{
      workspace_id: "ws-sit-audit",
      actor_id: "mcp",
      action: "agent.terminal_terminal_send_command",
      metadata: %{}
    })

    assert {:ok, digest} = GenServer.call(pid, :get_digest)
    assert digest.activity.last_mutation.action == "agent.terminal_terminal_send_command"
  end

  test "session output events update per-sid generation freshness" do
    pid = start_server("ws-sit-out")

    send(
      pid,
      {:terminal_session_event, %{type: :output, workspace_id: "ws-sit-out", sid: "s1", gen: 7}}
    )

    state = :sys.get_state(pid)
    assert state.last_output_gen["s1"] == 7
    assert %DateTime{} = state.last_output_at["s1"]
  end

  test "blocked_too_long raises on transition, audits, and clears when unblocked" do
    ws = "ws-sit-blocked"
    pid = start_server(ws)
    :ok = SituationServer.subscribe(ws)

    send(pid, {:agent_state_updated, "devide_sit_agent", "%1", blocked_entry(700)})

    assert_receive {:situation_risk, :raised, %{id: :blocked_too_long} = risk}, 2_000
    assert risk.severity == :critical
    assert risk.subject == "devide_sit_agent %1"

    assert Enum.any?(
             Audit.recent_for(ws, 20),
             &(&1.action == "operator.risk_raised" and &1.target_ref == "devide_sit_agent %1")
           )

    # Re-reporting the same blocked pane is not a transition: no second raise.
    send(pid, {:agent_state_updated, "devide_sit_agent", "%1", blocked_entry(800, "still stuck")})
    refute_receive {:situation_risk, :raised, %{id: :blocked_too_long}}, 600

    send(
      pid,
      {:agent_state_updated, "devide_sit_agent", "%1", %{blocked_entry(0) | state: :done}}
    )

    assert_receive {:situation_risk, :cleared, %{id: :blocked_too_long}}, 2_000

    assert Enum.any?(
             Audit.recent_for(ws, 20),
             &(&1.action == "operator.risk_cleared" and &1.target_ref == "devide_sit_agent %1")
           )
  end

  test "leaked_worktree raises from sweep results and clears on an empty sweep" do
    ws = "ws-sit-leak"
    pid = start_server(ws)
    :ok = SituationServer.subscribe(ws)
    await_boot_sweep(pid)

    alarm = %{
      path: "/tmp/wt-sit-leak",
      workspace_id: ws,
      runtime_id: nil,
      branch: "agent/claude/leak",
      dirty: true,
      reported: false,
      process_alive: false,
      exit_handoff: false,
      age_seconds: 90_000,
      reasons: ["unreported", "stale"]
    }

    send(pid, {:worktree_alarms, [alarm]})

    assert_receive {:situation_risk, :raised,
                    %{id: :leaked_worktree, subject: "/tmp/wt-sit-leak"}},
                   2_000

    assert [%{id: :leaked_worktree}] =
             Enum.filter(SituationServer.active_risks(ws), &(&1.id == :leaked_worktree))

    send(pid, {:worktree_alarms, []})
    assert_receive {:situation_risk, :cleared, %{id: :leaked_worktree}}, 2_000
    assert Enum.filter(SituationServer.active_risks(ws), &(&1.id == :leaked_worktree)) == []
  end

  test "active risks are reflected in the served digest" do
    ws = "ws-sit-digest-risks"
    pid = start_server(ws)
    :ok = SituationServer.subscribe(ws)

    send(pid, {:agent_state_updated, "devide_sit_agent", "%9", blocked_entry(700)})
    assert_receive {:situation_risk, :raised, %{id: :blocked_too_long}}, 2_000

    assert {:ok, digest} = GenServer.call(pid, :get_digest)
    assert Enum.any?(digest.risks, &(&1.id == :blocked_too_long))
  end

  test "deploy updates keep the digest serving a deploy section" do
    pid = start_server("ws-sit-deploy")

    send(pid, :deploy_poller_clear)

    assert {:ok, digest} = GenServer.call(pid, :get_digest)
    assert Map.has_key?(digest.deploy, :pipeline)
  end

  test "active_risks is whereis-safe when no server is running" do
    assert SituationServer.active_risks("ws-sit-none") == []
  end

  test "a restart closes dangling raises from the durable timeline without re-announcing" do
    ws = "ws-sit-seed"
    seed_workspace(ws)

    # A previous server instance raised this risk and died before clearing it.
    Audit.emit!(%{
      workspace_id: ws,
      actor_id: "situation_server",
      action: "operator.risk_raised",
      source: "operator",
      target_type: "risk",
      target_ref: "devide_seed %1",
      metadata: %{
        id: :blocked_too_long,
        severity: :critical,
        subject: "devide_seed %1",
        evidence: %{},
        suggestion: "unblock it"
      }
    })

    :ok = SituationServer.subscribe(ws)
    {:ok, pid} = SituationServer.ensure_started(ws)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # The condition no longer holds: the seeded standing risk clears (closing
    # the dangling raise) and is never re-announced as raised.
    assert_receive {:situation_risk, :cleared, %{id: :blocked_too_long}}, 2_000
    refute_receive {:situation_risk, :raised, %{id: :blocked_too_long}}, 200

    events = Audit.recent_for(ws, 20)

    assert Enum.any?(
             events,
             &(&1.action == "operator.risk_cleared" and &1.target_ref == "devide_seed %1")
           )

    # Exactly the pre-existing raise row — the restart added none.
    assert Enum.count(
             events,
             &(&1.action == "operator.risk_raised" and &1.target_ref == "devide_seed %1")
           ) == 1
  end

  test "degraded rebuild data suppresses clears until a clean digest confirms" do
    ws = "ws-sit-degraded"
    pid = start_server(ws)
    :ok = SituationServer.subscribe(ws)
    await_boot_sweep(pid)

    alarm = %{
      path: "/tmp/wt-sit-degraded",
      workspace_id: ws,
      runtime_id: nil,
      branch: "agent/claude/degraded",
      dirty: true,
      reported: false,
      process_alive: false,
      exit_handoff: false,
      age_seconds: 90_000,
      reasons: ["unreported", "stale"]
    }

    send(pid, {:worktree_alarms, [alarm]})
    assert_receive {:situation_risk, :raised, %{id: :leaked_worktree}}, 2_000

    # Simulate a rebuild whose constituent reads failed: the risk's evidence
    # vanished, but the digest says the data is degraded — no spurious clear.
    :sys.replace_state(pid, fn state ->
      %{state | digest: Map.put(state.digest, :degraded, [:sessions]), worktree_alarms: []}
    end)

    send(pid, :detect)
    refute_receive {:situation_risk, :cleared, %{id: :leaked_worktree}}, 600
    assert Enum.any?(SituationServer.active_risks(ws), &(&1.id == :leaked_worktree))

    # The next clean digest confirms the absence and the clear goes out.
    :sys.replace_state(pid, fn state ->
      %{state | digest: Map.put(state.digest, :degraded, [])}
    end)

    send(pid, :detect)
    assert_receive {:situation_risk, :cleared, %{id: :leaked_worktree}}, 2_000
  end

  test "served freshness ages from the last rebuild instead of staying frozen" do
    pid = start_server("ws-sit-fresh")
    assert {:ok, _} = GenServer.call(pid, :get_digest)

    :sys.replace_state(pid, fn state ->
      as_of = Map.put(state.freshness_as_of, :sessions, DateTime.add(DateTime.utc_now(), -7))
      %{state | freshness_as_of: as_of}
    end)

    assert {:ok, digest} = GenServer.call(pid, :get_digest)
    assert digest.freshness.sessions >= 7_000
  end

  test "ops:health pg saturation risks fold into the digest and clear" do
    ws = "ws-sit-ops"
    pid = start_server(ws)
    :ok = SituationServer.subscribe(ws)
    await_boot_sweep(pid)

    risk = %{
      id: :pg_saturation,
      severity: :critical,
      subject: "127.0.0.1:15432",
      detected_at: DateTime.utc_now(),
      evidence: %{reasons: [:utilization_critical], utilization: 0.95},
      suggestion: "Kill leaked wf_*/devide-<uuid> connections."
    }

    Phoenix.PubSub.broadcast(
      DevIDE.PubSub,
      DevIDE.Ops.PgProbe.topic(),
      {:ops_health, :pg_saturation, :raised, risk}
    )

    assert_receive {:situation_risk, :raised, %{id: :pg_saturation, subject: "127.0.0.1:15432"}},
                   2_000

    assert {:ok, digest} = GenServer.call(pid, :get_digest)
    assert Enum.any?(digest.risks, &(&1.id == :pg_saturation))

    assert Enum.any?(
             Audit.recent_for(ws, 20),
             &(&1.action == "operator.risk_raised" and &1.target_ref == "127.0.0.1:15432")
           )

    Phoenix.PubSub.broadcast(
      DevIDE.PubSub,
      DevIDE.Ops.PgProbe.topic(),
      {:ops_health, :pg_saturation, :cleared, risk}
    )

    assert_receive {:situation_risk, :cleared, %{id: :pg_saturation}}, 2_000
    assert Enum.filter(SituationServer.active_risks(ws), &(&1.id == :pg_saturation)) == []
  end
end
