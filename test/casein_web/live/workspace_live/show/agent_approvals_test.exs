defmodule CaseinWeb.WorkspaceLive.Show.AgentApprovalsTest do
  use Casein.TestCase, async: true

  import Phoenix.LiveViewTest

  alias Casein.AgentSessions.Provider.PendingRequest
  alias CaseinWeb.WorkspaceLive.Show.AgentApprovals

  test "option-list requests render the agent's own choices" do
    request =
      PendingRequest.new(%{
        provider_id: :grok_acp,
        session_ref: %{attachment_key: "att-1"},
        request_id: "request-ui",
        title: "Execute test suite",
        options: [
          %{id: "allow-once", label: "Allow once", kind: :allow_once},
          %{id: "reject-once", label: "Reject once", kind: :reject_once}
        ]
      })

    html = render_component(&AgentApprovals.pending_approvals/1, %{requests: [request]})

    assert html =~ "Allow once"
    assert html =~ "Reject once"
    assert html =~ ~s(phx-click="agent_approval:respond")
    assert html =~ ~s(phx-value-decision-kind="choice")
    assert html =~ ~s(phx-value-option-id="allow-once")
    refute html =~ "Approve with a policy amendment"
  end

  test "policy requests render accept, decline, and both amendment affordances" do
    request =
      PendingRequest.new(%{
        provider_id: :codex,
        session_ref: %{runtime_id: "runtime-1"},
        request_id: "approval-ui",
        title: "Command execution",
        detail: "mix test",
        options: nil
      })

    html = render_component(&AgentApprovals.pending_approvals/1, %{requests: [request]})

    assert html =~ "Approve once"
    assert html =~ "Reject"
    assert html =~ ~s(phx-value-decision-kind="accept")
    assert html =~ ~s(phx-value-decision-kind="decline")
    assert html =~ "Approve and amend exec policy"
    assert html =~ ~s(name="execpolicy-amendment")
    assert html =~ "Apply network policy amendment"
    assert html =~ ~s(name="network-policy-amendment")
  end

  test "request shape, not provider id, selects the affordances" do
    mislabeled_option_list =
      PendingRequest.new(%{
        provider_id: :codex,
        request_id: "choice-shaped",
        title: "Pick one",
        options: [%{id: "agent-choice", label: "Agent choice", kind: nil}]
      })

    mislabeled_policy =
      PendingRequest.new(%{
        provider_id: :grok_acp,
        request_id: "policy-shaped",
        title: "Decide policy",
        options: nil
      })

    option_html =
      render_component(&AgentApprovals.pending_approvals/1, %{requests: [mislabeled_option_list]})

    policy_html =
      render_component(&AgentApprovals.pending_approvals/1, %{requests: [mislabeled_policy]})

    assert option_html =~ "Agent choice"
    refute option_html =~ "Approve once"
    assert policy_html =~ "Approve once"
    refute policy_html =~ "Agent choice"
  end

  test "renders Codex and Grok requests in one operator approval queue" do
    codex =
      PendingRequest.new(%{
        provider_id: :codex,
        request_id: "approval-ui",
        title: "Command execution",
        detail: "mix test",
        options: nil
      })

    grok =
      PendingRequest.new(%{
        provider_id: :grok_acp,
        request_id: "request-ui",
        title: "Execute test suite",
        options: [%{id: "allow-once", label: "Allow once", kind: "allow_once"}]
      })

    html =
      render_component(&AgentApprovals.pending_approvals/1, %{requests: [codex, grok]})

    assert html =~ "Agent approvals"
    assert html =~ "2 pending"
    assert html =~ "Codex"
    assert html =~ "mix test"
    assert html =~ ~s(phx-click="agent_approval:respond")
    assert html =~ "Grok"
    assert html =~ "Execute test suite"
    assert html =~ "Agent paused · first response wins."
    assert html =~ ~s(phx-value-option-id="allow-once")
  end

  test "does not render without pending requests" do
    html =
      render_component(&AgentApprovals.pending_approvals/1, %{requests: []})

    refute html =~ "agent-approval-center"
  end
end
