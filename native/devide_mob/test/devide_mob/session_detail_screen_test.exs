defmodule DevideMob.SessionDetailScreenTest do
  use Mob.ScreenCase, async: false

  alias DevideMob.SessionConfig
  alias DevideMob.SessionDetailScreen

  setup do
    SessionConfig.clear_all()
    :ok
  end

  test "offline state renders a retry action" do
    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_status, "ws-1", :disconnected})

    assert_renderable(view, extra: [:icon])
    assert find(view, :icon, name: "back", text: "Back")
    assert length(find_all(view, :icon, name: "back")) == 1
    assert text(view) =~ "Session offline"
    assert text(view) =~ "Offline"
    assert find(view, :button, text: "Retry")
    assert find(view, :button, text: "Retry").props.height == 44.0
    assert SessionConfig.resume_context() == %{workspace_id: "ws-1", source: :workspace}
  end

  test "network disconnect explains host reachability" do
    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_status, "ws-1", {:disconnected, :network_unavailable}})

    assert_renderable(view, extra: [:icon])
    assert text(view) =~ "Network unavailable"
    assert text(view) =~ "cannot reach the DevIDE host"
    assert text(view) =~ "Network"
    assert find(view, :button, text: "Retry")
  end

  test "auth error offers pair again and routes to pairing" do
    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_status, "ws-1", {:error, :unauthorized}})

    assert_renderable(view, extra: [:icon])
    assert text(view) =~ "Pairing needs attention"
    assert text(view) =~ "access was revoked"
    assert text(view) =~ "Auth"
    assert find(view, :button, text: "Pair again").props.background == :primary
    assert find(view, :button, text: "Retry").props.background == :surface_raised

    view = render_info(view, {:tap, :pair_again})
    assert navigated_to(view) == DevideMob.PairingScreen
  end

  test "missing workspace error explains unpin or pair again recovery" do
    SessionConfig.pin_workspace("ws-1")

    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_status, "ws-1", {:error, :workspace_not_found}})

    assert_renderable(view, extra: [:icon])
    assert text(view) =~ "Workspace not found"
    assert text(view) =~ "deleted or moved"
    assert text(view) =~ "Missing"
    assert find(view, :button, text: "Retry")
    assert find(view, :button, text: "Unpin")
  end

  test "retry shows transition feedback until the workspace is live" do
    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_status, "ws-1", :disconnected})
      |> render_info({:tap, :retry})

    assert assigns(view).status == :connecting
    assert text(view) =~ "Reconnecting..."
    assert text(view) =~ "Connecting to session..."
    assert find(view, :progress)

    view = render_info(view, {:session_status, "ws-1", :joined})

    assert text(view) =~ "Workspace is live"

    view = render_info(view, {:clear_notice, "Workspace is live"})
    refute text(view) =~ "Workspace is live"
  end

  test "header truncates long workspace names" do
    view =
      mount_screen(SessionDetailScreen, %{
        workspace_id: "workspace-with-a-very-long-human-hostile-identifier"
      })

    assert text(view) =~ "workspace-with-a-very-lon..."
  end

  test "mount persists optional session id resume context" do
    mount_screen(SessionDetailScreen, %{
      workspace_id: "ws-1",
      session_id: "run-1",
      source: :review
    })

    assert SessionConfig.resume_context() == %{
             workspace_id: "ws-1",
             session_id: "run-1",
             source: :review
           }
  end

  test "pin and unpin update device-local workspace pins" do
    view = mount_screen(SessionDetailScreen, %{workspace_id: "ws-1"})

    view = render_info(view, {:tap, :pin})
    assert assigns(view).pinned?
    assert SessionConfig.pinned?("ws-1")

    view = render_info(view, {:tap, :unpin})
    refute assigns(view).pinned?
    refute SessionConfig.pinned?("ws-1")
  end

  test "activity reasons render below the main decision row" do
    snapshot = %{
      "mode" => "review",
      "current_run" => nil,
      "recent_audit" => [
        %{"action" => "deploy", "decision" => "deny", "reason" => "manual review required"}
      ],
      "active_agents" => []
    }

    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_snapshot, "ws-1", snapshot})

    assert_renderable(view, extra: [:icon])
    assert text(view) =~ "manual review required"

    activity =
      view
      |> find_all(:column)
      |> Enum.find(fn node ->
        Enum.any?(node.children, &match?(%{type: :row}, &1))
      end)

    assert activity
  end

  test "detail surfaces run metadata, recent runs, and agent status" do
    snapshot = %{
      "mode" => "review",
      "pending_reviews" => 2,
      "current_run" => %{
        "status" => "running",
        "command_id" => "mix test",
        "source" => "codex",
        "trigger" => "manual",
        "plane" => "dev",
        "protocol" => "mcp",
        "assignment_id" => "assign-1",
        "safe_action_id" => "safe-test",
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "last_event_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      },
      "recent_runs" => [
        %{
          "status" => "succeeded",
          "command_id" => "mix format",
          "finished_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "exit_code" => 0
        }
      ],
      "recent_audit" => [],
      "active_agents" => [
        %{
          "tool" => "terminal_send_command",
          "summary" => "running tests",
          "source" => "terminal_mcp",
          "status" => "ok",
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        },
        %{
          "tool" => "preview_open",
          "summary" => "checking UI",
          "source" => "preview_mcp",
          "status" => "error",
          "at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      ]
    }

    view =
      SessionDetailScreen
      |> mount_screen(%{workspace_id: "ws-1"})
      |> render_info({:session_snapshot, "ws-1", snapshot})

    assert_renderable(view, extra: [:icon])
    assert text(view) =~ "Now"
    assert text(view) =~ "1 active run"
    assert text(view) =~ "2 agents"
    assert text(view) =~ "2 reviews"
    assert text(view) =~ "Source codex"
    assert text(view) =~ "Trigger manual"
    assert text(view) =~ "Plane dev"
    assert text(view) =~ "Protocol mcp"
    assert text(view) =~ "Assignment assign-1"
    assert text(view) =~ "Safe action safe-test"
    # Runs and audit rows now share one reverse-chronological work log.
    assert text(view) =~ "Work log"
    assert text(view) =~ "mix format"
    assert text(view) =~ "succeeded"
    assert text(view) =~ "terminal_send_command"
    assert text(view) =~ "terminal mcp"
    assert text(view) =~ "ok"
    assert text(view) =~ "preview_open"
    assert text(view) =~ "preview mcp"
    assert text(view) =~ "error"
  end

  describe "instructing the agent" do
    test "the composer only appears when the workspace has agents in flight" do
      idle =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info({:session_snapshot, "ws-1", %{"mode" => "agent", "active_agents" => []}})

      refute text(idle) =~ "Instruct the agent"

      busy =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info(
          {:session_snapshot, "ws-1",
           %{"mode" => "agent", "active_agents" => [%{"tool" => "claude"}]}}
        )

      assert_renderable(busy, extra: [:icon])
      assert text(busy) =~ "Instruct the agent"
      assert find(busy, :button, text: "Send to agent")
      assert find(busy, :text, text: "Run tests")
    end

    test "an empty instruction is refused before it reaches the channel" do
      view =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info({:session_snapshot, "ws-1", %{"active_agents" => [%{"tool" => "claude"}]}})
        |> render_info({:change, :instruction, "   "})
        |> render_info({:tap, :send_instruction})

      assert assigns(view).instruction_state == :idle
      assert text(view) =~ "Type an instruction first"
    end

    test "sending shows progress, then the server's outcome" do
      view =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info({:session_snapshot, "ws-1", %{"active_agents" => [%{"tool" => "claude"}]}})
        |> render_info({:change, :instruction, "run the failing test again"})
        |> render_info({:tap, :send_instruction})

      assert assigns(view).instruction_state == :sending
      assert text(view) =~ "Pasting into the agent pane"
      assert find(view, :button, text: "Sending...").props.disabled

      view = render_info(view, {:agent_instruction_result, "ws-1", {:ok, %{"submitted" => true}}})

      assert assigns(view).instruction_state == :idle
      # Cleared, so the next instruction starts from an empty field.
      assert assigns(view).instruction == ""
      assert text(view) =~ "Sent to the agent"
    end

    test "an instruction typed offline is queued, shown, and retryable" do
      view =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info({:session_snapshot, "ws-1", %{"active_agents" => [%{"tool" => "claude"}]}})
        |> render_info({:change, :instruction, "look at the failing spec"})
        |> render_info({:tap, :send_instruction})

      # The channel client is not running in this test, so the send never
      # reaches a server — exactly the offline case.
      DevideMob.Outbox.enqueue("ws-1", "look at the failing spec")

      view =
        render_info(
          view,
          {:agent_instruction_result, "ws-1", {:queued, %{reason: :not_connected, attempts: 1}}}
        )

      assert text(view) =~ "Queued — it will send when the phone reconnects"
      # Accepted from the user's point of view: the field clears.
      assert assigns(view).instruction == ""
      assert assigns(view).queued_instructions == 1
      assert text(view) =~ "1 instruction waiting to send"
      assert find(view, :button, text: "Retry")

      view = render_info(view, {:tap, :retry_outbox})
      assert text(view) =~ "Retrying queued instructions"
    end

    test "a failure explains itself in the composer" do
      view =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info({:session_snapshot, "ws-1", %{"active_agents" => [%{"tool" => "claude"}]}})
        |> render_info({:change, :instruction, "hello"})
        |> render_info({:tap, :send_instruction})
        |> render_info({:agent_instruction_result, "ws-1", {:error, "agent_pane_not_found"}})

      assert text(view) =~ "no agent pane is running in this workspace"
      # The text survives a failed send so it can be retried.
      assert assigns(view).instruction == "hello"
    end

    test "a quick reply sends without typing" do
      view =
        SessionDetailScreen
        |> mount_screen(%{workspace_id: "ws-1"})
        |> render_info({:session_snapshot, "ws-1", %{"active_agents" => [%{"tool" => "claude"}]}})
        |> render_info({:tap, {:quick_reply, "Run the test suite and report what fails."}})

      assert assigns(view).instruction_state == :sending
    end
  end
end
