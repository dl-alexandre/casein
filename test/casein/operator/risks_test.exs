defmodule Casein.Operator.RisksTest do
  use Casein.TestCase, async: true

  alias Casein.Operator.Risks

  @generated_at ~U[2026-07-16 12:00:00Z]

  defp digest(overrides) do
    Map.merge(
      %{
        workspace_id: "ws-1",
        generated_at: @generated_at,
        sessions: [],
        agent_layout: %{status: "ready", ready: true},
        worktrees: [],
        deploy: %{running_revision: "abc1234", drift: false, pipeline: :ok, phase: nil},
        activity: %{recent: [], last_mutation: nil},
        risks: []
      },
      Map.new(overrides)
    )
  end

  test "detect returns no risks for a healthy digest" do
    assert Risks.detect(digest([])) == []
  end

  test "dirty_no_handoff fires for a dirty worktree without landing or handoff" do
    worktree = %{
      path: "/tmp/wt-1",
      branch: "agent/topic",
      dirty_count: 2,
      status: "dirty",
      exit_status: "wip"
    }

    assert [risk] = Risks.detect(digest(worktrees: [worktree]))
    assert risk.id == :dirty_no_handoff
    assert risk.severity == :warn
    assert risk.subject == "/tmp/wt-1"
    assert risk.detected_at == @generated_at
    assert risk.evidence == %{branch: "agent/topic", dirty_count: 2, exit_status: "wip"}
    assert risk.suggestion =~ "terminal_report_worktree"
  end

  test "dirty_no_handoff stays quiet when the work landed or a handoff exists" do
    landed = %{path: "/tmp/wt-1", status: "dirty", dirty_count: 2, exit_status: "landed"}

    handed_off = %{
      path: "/tmp/wt-2",
      status: "dirty",
      dirty_count: 1,
      exit_status: "handoff",
      handoff: "PR #42 open, waiting on review"
    }

    clean = %{path: "/tmp/wt-3", status: "clean", dirty_count: 0}

    assert Risks.detect(digest(worktrees: [landed, handed_off, clean])) == []
  end

  test "unpushed_work fires for an ahead worktree whose agent reported an exit" do
    worktree = %{
      path: "/tmp/wt-1",
      branch: "agent/topic",
      upstream: "origin/agent/topic",
      ahead: 2,
      behind: 0,
      status: "clean",
      dirty_count: 0,
      exit_status: "landed",
      observed_at: DateTime.to_iso8601(@generated_at)
    }

    assert [risk] = Risks.detect(digest(worktrees: [worktree]))
    assert risk.id == :unpushed_work
    assert risk.severity == :warn
    assert risk.subject == "/tmp/wt-1"
    assert risk.evidence.ahead == 2
    assert risk.evidence.upstream == "origin/agent/topic"
    assert risk.suggestion =~ "Push the branch"
  end

  test "unpushed_work fires for an ahead worktree with a stale observation" do
    stale = @generated_at |> DateTime.add(-16 * 60, :second) |> DateTime.to_iso8601()

    worktree = %{
      path: "/tmp/wt-1",
      upstream: "origin/agent/topic",
      ahead: 1,
      behind: 0,
      status: "clean",
      dirty_count: 0,
      observed_at: stale
    }

    assert [risk] = Risks.detect(digest(worktrees: [worktree]))
    assert risk.id == :unpushed_work
  end

  test "unpushed_work stays quiet while the agent looks active or nothing is ahead" do
    fresh = @generated_at |> DateTime.add(-60, :second) |> DateTime.to_iso8601()

    active = %{
      path: "/tmp/wt-1",
      upstream: "origin/a",
      ahead: 3,
      status: "clean",
      dirty_count: 0,
      observed_at: fresh
    }

    pushed = %{
      path: "/tmp/wt-2",
      upstream: "origin/b",
      ahead: 0,
      behind: 2,
      status: "clean",
      dirty_count: 0,
      exit_status: "landed",
      observed_at: fresh
    }

    no_upstream = %{
      path: "/tmp/wt-3",
      status: "clean",
      dirty_count: 0,
      exit_status: "wip",
      observed_at: fresh
    }

    assert Risks.detect(digest(worktrees: [active, pushed, no_upstream])) == []
  end

  test "frozen_scope_active reports each observed freeze sentinel as info" do
    scopes = [
      %{path: "/tmp/ws", sentinel: "/tmp/ws/.claude/.freeze"},
      %{path: "/tmp/wt-1", sentinel: "/tmp/wt-1/.claude/.freeze", raw: "lib/foo"}
    ]

    assert [ws_risk, wt_risk] = Risks.detect(digest(frozen_scopes: scopes))

    assert ws_risk.id == :frozen_scope_active
    assert ws_risk.severity == :info
    assert ws_risk.subject == "/tmp/ws"
    assert ws_risk.evidence == %{sentinel: "/tmp/ws/.claude/.freeze"}
    assert ws_risk.suggestion =~ "/phx:freeze off"

    assert wt_risk.subject == "/tmp/wt-1"
    assert wt_risk.evidence == %{sentinel: "/tmp/wt-1/.claude/.freeze", raw: "lib/foo"}
  end

  test "deploy_drift fires when the running revision is behind" do
    deploy = %{running_revision: "abc1234", drift: true, pipeline: :ok, phase: nil}

    assert [risk] = Risks.detect(digest(deploy: deploy))
    assert risk.id == :deploy_drift
    assert risk.severity == :warn
    assert risk.subject == "abc1234"
  end

  test "deploy_drift stays quiet when drift is unknown (nil)" do
    deploy = %{running_revision: "abc1234", drift: nil, pipeline: :unknown, phase: nil}
    assert Risks.detect(digest(deploy: deploy)) == []
  end

  test "deploy_gate_failed is critical when the pipeline failed at the gate" do
    deploy = %{running_revision: "abc1234", drift: false, pipeline: :failed, phase: "gate"}

    assert [risk] = Risks.detect(digest(deploy: deploy))
    assert risk.id == :deploy_gate_failed
    assert risk.severity == :critical
    assert risk.evidence == %{pipeline: :failed, phase: "gate"}
  end

  test "deploy_gate_failed ignores failures in other phases" do
    deploy = %{running_revision: "abc1234", drift: false, pipeline: :failed, phase: "build"}
    assert Risks.detect(digest(deploy: deploy)) == []
  end

  test "agent_blocked fires once per blocked pane with a session-scoped subject" do
    sessions = [
      %{
        sid: "main",
        tmux_session: "devide_alpha_main",
        panes: [
          %{id: "%1", agent_state: :blocked, agent_state_age_s: 30, task_summary: "perm prompt"},
          %{id: "%2", agent_state: :working}
        ]
      },
      %{sid: "other", tmux_session: "devide_alpha_other", panes: [%{id: "%3"}]}
    ]

    assert [risk] = Risks.detect(digest(sessions: sessions))
    assert risk.id == :agent_blocked
    assert risk.severity == :warn
    assert risk.subject == "devide_alpha_main %1"
    assert risk.evidence == %{agent_state_age_s: 30, task_summary: "perm prompt"}
    assert risk.suggestion =~ "terminal_capture_agent"
  end

  test "missing_agent_pane fires from the agent layout status" do
    layout = %{status: "missing_agent_pane", ready: false}

    assert [risk] = Risks.detect(digest(agent_layout: layout))
    assert risk.id == :missing_agent_pane
    assert risk.severity == :info
    assert risk.subject == "ws-1"
    assert risk.suggestion =~ "agent_pair"
  end

  test "detect stacks independent risks in rule order" do
    deploy = %{running_revision: "abc1234", drift: true, pipeline: :failed, phase: "gate"}
    worktree = %{path: "/tmp/wt-1", status: "dirty", dirty_count: 1}

    risks = Risks.detect(digest(deploy: deploy, worktrees: [worktree]))

    assert Enum.map(risks, & &1.id) == [:dirty_no_handoff, :deploy_drift, :deploy_gate_failed]
  end
end
