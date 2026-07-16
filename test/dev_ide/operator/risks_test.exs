defmodule DevIDE.Operator.RisksTest do
  use DevIDE.TestCase, async: true

  alias DevIDE.Operator.Risks

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
