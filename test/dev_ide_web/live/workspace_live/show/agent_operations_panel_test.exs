defmodule DevIdeWeb.WorkspaceLive.Show.AgentOperationsPanelTest do
  use DevIDE.TestCase, async: true

  import Phoenix.LiveViewTest

  alias DevIDE.Codex.Event
  alias DevIdeWeb.WorkspaceLive.Show.AgentOperationsPanel

  test "renders globally pinned approvals, a nested thread tree, timeline, and usage" do
    threads = [
      thread("root", nil, "active", %{
        total: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
      }),
      thread(
        "child",
        "root",
        "active",
        %{total: %{input_tokens: 30, output_tokens: 5, total_tokens: 35}},
        [
          "waiting_on_approval"
        ]
      )
    ]

    approval = %{
      id: "approval-ui",
      runtime_id: "runtime-ui",
      thread_id: "child",
      kind: "command_execution",
      status: "pending",
      requested_at: ~U[2026-07-16 09:30:00Z],
      payload: %{"command" => "mix test", "reason" => "Verify the change"}
    }

    event =
      Event.new!(
        :turn_started,
        %{
          workspace_id: "ws-ui",
          runtime_id: "runtime-ui",
          transport: :app_server,
          sequence: 1,
          occurred_at: ~U[2026-07-16 09:31:00Z]
        },
        thread_id: "child",
        turn_id: "turn-ui",
        payload: %{status: :in_progress}
      )

    html =
      render_component(&AgentOperationsPanel.agent_operations_panel/1, %{
        workspace: %{id: "ws-ui"},
        loaded?: true,
        threads: threads,
        approvals: [approval],
        selected_thread_id: "child",
        timeline: [event],
        live_delta: "Working through the tests…",
        exec_form: Phoenix.Component.to_form(%{"prompt" => ""}, as: :codex_exec),
        exec_run: nil,
        error: nil
      })

    assert html =~ "Agent Operations"
    assert html =~ "Pending approvals stay visible"
    assert html =~ "mix test"
    assert html =~ "Thread tree"
    assert html =~ "Turn started"
    assert html =~ "Streaming response"
    assert html =~ "155"
    assert html =~ ~s(phx-value-approval-id="approval-ui")
  end

  defp thread(id, parent, status, usage, flags \\ []) do
    %{
      thread_id: id,
      parent_thread_id: parent,
      runtime_id: "runtime-ui",
      transport: :app_server,
      status: status,
      active_flags: flags,
      agent_role: if(parent, do: "reviewer", else: nil),
      agent_nickname: nil,
      preview: nil,
      usage: usage
    }
  end
end
