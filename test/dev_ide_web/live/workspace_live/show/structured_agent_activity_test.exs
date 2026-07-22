defmodule DevIdeWeb.WorkspaceLive.Show.StructuredAgentActivityTest do
  use DevIDE.TestCase, async: true

  import Phoenix.LiveViewTest

  alias DevIDE.Codex.Event
  alias DevIdeWeb.WorkspaceLive.Show.StructuredAgentActivity

  test "renders nested threads, lifecycle events, streaming output, and usage in History" do
    threads = [
      thread("root", nil, "active", %{
        total: %{input_tokens: 100, output_tokens: 20, total_tokens: 120}
      }),
      thread(
        "child",
        "root",
        "active",
        %{total: %{input_tokens: 30, output_tokens: 5, total_tokens: 35}},
        ["waiting_on_approval"]
      )
    ]

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
      render_component(&StructuredAgentActivity.structured_agent_activity/1, %{
        loaded?: true,
        threads: threads,
        selected_thread_id: "child",
        timeline: [event],
        live_delta: "Working through the tests…",
        error: nil
      })

    assert html =~ "Structured agent activity"
    assert html =~ "Codex lifecycle"
    assert html =~ "Turn started"
    assert html =~ "Streaming"
    assert html =~ "155"
    assert html =~ "130 input"
    assert html =~ "25 output"
    assert html =~ "turn turn-ui"
    assert html =~ "App server"
    assert html =~ ~s(id="structured-agent-refresh-button")
    assert html =~ ~s(phx-click="codex:refresh")
    assert html =~ ~s(phx-value-thread-id="child")
    refute html =~ ~r/<details[^>]*id="structured-agent-activity"[^>]*\sopen(?:=|\s|>)/
    refute html =~ "Approve once"
    refute html =~ "Read-only background task"
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
