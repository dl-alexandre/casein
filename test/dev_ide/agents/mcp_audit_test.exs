defmodule DevIDE.Agents.MCPAuditTest do
  @moduledoc """
  Regression coverage for which terminal MCP tools emit durable Audit records.

  The agent-pane shortcuts (`terminal_send_agent_keys` /
  `terminal_send_agent_command`) are real mutations but were historically
  missing from the audit list, so agent-pane writes went unaudited. These tests
  pin every mutating tool — including the agent_* variants — to an Audit record.
  """
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.{Activity, AgentEvents, MCPAudit}
  alias DevIDE.Audit
  alias DevIDE.Audit.MemoryAdapter
  alias DevIDE.PreviousSessions

  setup do
    prev_adapter = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, MemoryAdapter)
    Activity.clear()
    MemoryAdapter.clear()

    on_exit(fn ->
      Activity.clear()
      MemoryAdapter.clear()

      if prev_adapter,
        do: Application.put_env(:dev_ide, :audit_adapter, prev_adapter),
        else: Application.delete_env(:dev_ide, :audit_adapter)
    end)

    :ok
  end

  describe "record_terminal/3 audit emission" do
    for tool <- ~w(
          terminal_send_command
          terminal_send_keys
          terminal_send_agent_command
          terminal_send_agent_keys
        ) do
      test "emits an Audit record for mutating tool #{tool}" do
        tool = unquote(tool)
        ws = "ws-audit-#{System.unique_integer([:positive])}"

        args = %{
          "workspace_id" => ws,
          "command" => "mix test",
          "keys" => "Enter"
        }

        assert :ok = MCPAudit.record_terminal(tool, args, {:ok, %{}})

        actions = ws |> Audit.recent_for(10) |> Enum.map(& &1.action)
        assert ("agent.terminal_" <> tool) in actions
      end
    end

    test "does not emit an Audit record for a read-only tool" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"

      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_list_sessions",
                 %{"workspace_id" => ws},
                 {:ok, %{}}
               )

      assert Audit.recent_for(ws, 10) == []

      assert [%{event_type: "mcp.completed", status: "ok"} = event] =
               AgentEvents.recent_for(ws)

      assert event.payload["tool"] == "terminal_list_sessions"
    end

    test "a failed mutating tool persists a durable record with the error reason" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"

      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_agent_command",
                 %{"workspace_id" => ws, "command" => "rm -rf /"},
                 {:error, :boom}
               )

      [event] = Audit.recent_for(ws, 10)
      assert event.action == "agent.terminal_terminal_send_agent_command"
      assert event.reason == :boom
      assert event.metadata[:error] == "boom"
    end

    test "a failed read-only tool stays memory-only" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"

      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_capture",
                 %{"workspace_id" => ws},
                 {:error, :boom}
               )

      assert Audit.recent_for(ws, 10) == []
      assert [%{status: :error}] = Activity.recent(ws, 1)

      assert [%{event_type: "mcp.completed", status: "error"} = event] =
               AgentEvents.recent_for(ws)

      refute inspect(event) =~ "rm -rf"
    end

    test "unrecognized error shapes normalize to :tool_error with sanitized detail" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"

      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_command",
                 %{"workspace_id" => ws, "command" => "true"},
                 {:error, "pipe burst: token=secret-token"}
               )

      [event] = Audit.recent_for(ws, 10)
      assert event.reason == :tool_error
      assert event.metadata[:error_message] =~ "pipe burst"
      refute inspect(event.metadata) =~ "secret-token"
    end

    test "stamps source and tool columns on emitted events" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"

      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_command",
                 %{"workspace_id" => ws, "command" => "true"},
                 {:ok, %{}}
               )

      [event] = Audit.recent_for(ws, 10)
      assert event.source == "terminal_mcp"
      assert event.tool == "terminal_send_command"
      assert [event] == Audit.recent_for_tool(ws, "terminal_send_command", 10)
    end

    test "prefers the authenticated actor over args and the mcp fallback" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"
      args = %{"workspace_id" => ws, "command" => "true"}

      assert :ok =
               MCPAudit.record_terminal("terminal_send_command", args, {:ok, %{}},
                 actor: "ws:#{ws}"
               )

      assert :ok = MCPAudit.record_terminal("terminal_send_command", args, {:ok, %{}}, [])

      actors = ws |> Audit.recent_for(10) |> Enum.map(& &1.actor_id)
      assert "ws:#{ws}" in actors
      assert "mcp" in actors
    end

    test "a failed mutating call with no resolvable workspace stays memory-only, no crash" do
      # Non-pre-scoped endpoint, scope resolution failed: no workspace_id
      # anywhere. The durable row needs a NOT NULL workspace_id, so it is
      # skipped instead of raising out of the request.
      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_command",
                 %{"command" => "true"},
                 {:error, :missing_workspace_id}
               )

      assert Audit.list() == []
    end

    test "a trusted workspace override beats a caller-claimed workspace in args" do
      # Scope-rejection path: raw args claim workspace B, but the endpoint's
      # authenticated workspace (the override) decides where rows land — a
      # token scoped to A must not forge rows in B.
      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_command",
                 %{"workspace_id" => "ws-victim", "command" => "attacker text"},
                 {:error, :workspace_scope_mismatch},
                 actor: "ws:ws-attacker",
                 workspace_id: "ws-attacker"
               )

      assert Audit.recent_for("ws-victim", 10) == []
      assert Activity.recent("ws-victim", 10) == []

      [event] = Audit.recent_for("ws-attacker", 10)
      assert event.reason == :workspace_scope_mismatch

      # A nil override (non-pre-scoped endpoint) drops the durable row rather
      # than falling back to the untrusted args.
      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_command",
                 %{"workspace_id" => "ws-victim", "command" => "attacker text"},
                 {:error, :workspace_scope_mismatch},
                 workspace_id: nil
               )

      assert Audit.recent_for("ws-victim", 10) == []
    end

    test "terminal metadata redacts secret-shaped command text before persistence" do
      ws = "ws-audit-#{System.unique_integer([:positive])}"

      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_command",
                 %{"workspace_id" => ws, "command" => "curl -H token=secret-token"},
                 {:ok, %{}}
               )

      [event] = Audit.recent_for(ws, 10)
      assert event.metadata[:command] =~ "[REDACTED]"
      refute inspect(event.metadata) =~ "secret-token"
    end

    test "Activity entry carries the same correlation_id as the audit row" do
      assert :ok =
               DevIDE.Signals.Context.with_new(fn ->
                 MCPAudit.record_terminal(
                   "terminal_send_command",
                   %{"workspace_id" => "ws-corr", "command" => "true"},
                   {:ok, %{}}
                 )
               end)

      [event] = Audit.recent_for("ws-corr", 1)
      [entry] = Activity.recent("ws-corr", 1)

      correlation_id = event.metadata["correlation_id"]
      assert is_binary(correlation_id)
      assert entry.metadata["correlation_id"] == correlation_id
    end
  end

  describe "record_artifact/5 workspace attribution" do
    test "never derives the durable row's workspace from raw args" do
      # Scope-rejection call shape (artifact_mcp error branch): workspace nil,
      # args claim a victim workspace. No durable row may land there.
      assert :ok =
               MCPAudit.record_artifact(
                 nil,
                 "artifact_update",
                 %{"workspace_id" => "ws-victim", "artifact_id" => "a1"},
                 {:error, :workspace_scope_mismatch}
               )

      assert Audit.recent_for("ws-victim", 10) == []
    end

    test "persists failed mutating calls under the validated workspace" do
      assert :ok =
               MCPAudit.record_artifact(
                 "ws-artifact",
                 "artifact_update",
                 %{"artifact_id" => "a1"},
                 {:error, :not_found}
               )

      [event] = Audit.recent_for("ws-artifact", 10)
      assert event.action == "agent.artifact_artifact_update"
      assert event.reason == :not_found
    end
  end

  describe "record_preview/4 activity metadata" do
    test "promotes screenshot result artifacts into searchable preview context" do
      assert :ok =
               MCPAudit.record_preview(
                 "ws-preview",
                 "preview_screenshot",
                 %{"session_id" => "preview-1", "path" => "/dashboard"},
                 {:ok,
                  %{
                    artifact_path: "/preview-artifacts/ws-preview/snap.png",
                    url: "http://localhost:4000/dashboard?token=secret-token",
                    display_url: "/preview-proxy/ws-preview/4000/dashboard",
                    source_url: "http://localhost:4000/dashboard",
                    title: "Dashboard",
                    status: "ready"
                  }}
               )

      [entry] = Activity.recent("ws-preview", 1)
      metadata = entry.metadata

      assert metadata.artifact_url == "/preview-artifacts/ws-preview/snap.png"
      assert metadata.screenshot_url == "/preview-artifacts/ws-preview/snap.png"
      assert metadata.url == "http://localhost:4000/dashboard?token=[REDACTED]"
      assert metadata.display_url == "/preview-proxy/ws-preview/4000/dashboard"
      assert metadata.source_url == "http://localhost:4000/dashboard"
      assert metadata.preview_title == "Dashboard"
      assert metadata.preview_status == "ready"
      refute inspect(metadata) =~ "secret-token"

      assert %{results: [%{preview: preview}]} =
               PreviousSessions.search("ws-preview",
                 query: "snap.png",
                 sessions: [],
                 audit_events: [],
                 activity_entries: [entry],
                 labels_by_session: %{}
               )

      assert preview.screenshot_url == "/preview-artifacts/ws-preview/snap.png"
      assert preview.artifact_url == "/preview-artifacts/ws-preview/snap.png"
      assert preview.url == "http://localhost:4000/dashboard?token=[REDACTED]"
      assert preview.title == "Dashboard"
      assert preview.status == "ready"
    end

    test "promotes recording artifacts without storing raw video paths" do
      assert :ok =
               MCPAudit.record_preview(
                 "ws-preview",
                 "preview_record_stop",
                 %{"session_id" => "preview-2"},
                 {:ok,
                  %{
                    recording_id: "rec-2",
                    artifact_path: "/preview-artifacts/ws-preview/rec-2.webm",
                    url: "/preview-artifacts/ws-preview/rec-2.webm",
                    video_path: "/tmp/devide-recordings/secret.webm"
                  }}
               )

      [entry] = Activity.recent("ws-preview", 1)
      metadata = entry.metadata

      assert metadata.artifact_url == "/preview-artifacts/ws-preview/rec-2.webm"
      assert metadata.recording_id == "rec-2"
      assert metadata.recording_url == "/preview-artifacts/ws-preview/rec-2.webm"
      assert metadata.recording_status == "recorded"
      refute Map.has_key?(metadata, :artifact_path)
      refute Map.has_key?(metadata, :video_path)
      refute Map.has_key?(metadata, :recording_path)
      refute Map.has_key?(metadata, :screenshot_url)
      refute inspect(metadata) =~ "/tmp/devide-recordings"

      assert %{results: [%{preview: preview}]} =
               PreviousSessions.search("ws-preview",
                 query: "rec-2",
                 sessions: [],
                 audit_events: [],
                 activity_entries: [entry],
                 labels_by_session: %{}
               )

      assert preview.recording_id == "rec-2"
      assert preview.recording_url == "/preview-artifacts/ws-preview/rec-2.webm"
      assert preview.recording_status == "recorded"
      refute Map.has_key?(preview, :recording_path)
    end
  end
end
