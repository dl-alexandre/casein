defmodule DevIDE.Agents.MCPAuditTest do
  @moduledoc """
  Regression coverage for which terminal MCP tools emit durable Audit records.

  The agent-pane shortcuts (`terminal_send_agent_keys` /
  `terminal_send_agent_command`) are real mutations but were historically
  missing from the audit list, so agent-pane writes went unaudited. These tests
  pin every mutating tool — including the agent_* variants — to an Audit record.
  """
  use ExUnit.Case, async: false

  alias DevIDE.Agents.MCPAudit
  alias DevIDE.Agents.Activity
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

        args = %{
          "workspace_id" => "ws-audit",
          "command" => "mix test",
          "keys" => "Enter"
        }

        assert :ok = MCPAudit.record_terminal(tool, args, {:ok, %{}})

        actions = "ws-audit" |> Audit.recent_for(10) |> Enum.map(& &1.action)
        assert ("agent.terminal_" <> tool) in actions
      end
    end

    test "does not emit an Audit record for a read-only tool" do
      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_list_sessions",
                 %{"workspace_id" => "ws-audit"},
                 {:ok, %{}}
               )

      assert Audit.recent_for("ws-audit", 10) == []
    end

    test "does not emit an Audit record when a mutating tool errors" do
      assert :ok =
               MCPAudit.record_terminal(
                 "terminal_send_agent_command",
                 %{"workspace_id" => "ws-audit", "command" => "rm -rf /"},
                 {:error, :boom}
               )

      assert Audit.recent_for("ws-audit", 10) == []
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
