defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovalsTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest

  alias CaseinWeb.WorkspaceLive.Show.AgentApprovals

  test "renders Codex and Grok requests in one operator approval queue" do
    codex = %{
      id: "approval-ui",
      thread_id: "thread-ui",
      kind: "command_execution",
      status: "pending",
      requested_at: ~U[2026-07-16 09:30:00Z],
      payload: %{"command" => "mix test", "reason" => "Verify the change"}
    }

    grok = %{
      dom_id: "grok-ui",
      attachment_key: "attachment-ui",
      request_id: "request-ui",
      session_id: "session-ui",
      session_label: "session-ui",
      title: "Execute test suite",
      options: [%{option_id: "allow-once", name: "Allow once", kind: "allow_once"}]
    }

    html =
      render_component(&AgentApprovals.agent_approvals/1, %{
        codex_approvals: [codex],
        grok_requests: [grok]
      })

    assert html =~ "Agent approvals"
    assert html =~ "2 pending"
    assert html =~ "Codex"
    assert html =~ "mix test"
    assert html =~ ~s(phx-click="codex:resolve_approval")
    assert html =~ "Grok"
    assert html =~ "Execute test suite"
    assert html =~ "Agent paused · first response wins."
    assert html =~ ~s(phx-click="grok_permission:respond")
  end

  test "does not render without pending requests" do
    html =
      render_component(&AgentApprovals.agent_approvals/1, %{
        codex_approvals: [%{id: "done", status: "resolved"}],
        grok_requests: []
      })

    refute html =~ "agent-approval-center"
  end
end
