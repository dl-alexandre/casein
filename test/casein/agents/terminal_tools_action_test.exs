defmodule Casein.Agents.TerminalToolsActionTest do
  @moduledoc """
  Unit tests for the Jido.Action-backed terminal tool surface.

  Pins tools/list wire shapes and ToolAction validation semantics while the
  legacy conn/contract suites stay unchanged.
  """
  use ExUnit.Case, async: true

  alias Casein.Agents.TerminalTools

  describe "definitions/0" do
    test "exposes terminal tools plus annotation tools" do
      names = TerminalTools.definitions() |> Enum.map(& &1.name)

      assert length(names) == 47

      for expected <- [
            "terminal_list_sessions",
            "terminal_host_capacity",
            "terminal_host_health",
            "terminal_context",
            "terminal_topology",
            "terminal_capture",
            "terminal_agent_pane",
            "terminal_capture_agent",
            "terminal_agent_transcript",
            "terminal_send_agent_keys",
            "terminal_send_agent_command",
            "terminal_paste_agent_text",
            "terminal_set_next_prompt",
            "terminal_clear_next_prompt",
            "terminal_get_next_prompt",
            "terminal_request_clarification",
            "terminal_request_human_input",
            "terminal_say",
            "terminal_inbox",
            "terminal_send_keys",
            "terminal_send_command",
            "terminal_bind_issue",
            "terminal_layout_snapshot",
            "terminal_layout_apply",
            "terminal_work_handle_create",
            "terminal_work_handle_get",
            "terminal_work_handle_list",
            "file_open_in_pane",
            "diff_open",
            "run_open",
            "terminal_set_agent_label",
            "terminal_report_worktree",
            "terminal_report_agent_state",
            "terminal_wait_agent_state",
            "orchestration_status",
            "worker_status",
            "orchestration_list_workers",
            "runtime_signal",
            "worker_launch",
            "worker_cancel",
            "worktree_status",
            "worktree_changed_paths",
            "worktree_diff",
            "gate_report",
            "mcp_self_test",
            "annotation_list",
            "annotation_propose"
          ] do
        assert expected in names
      end
    end

    test "typed human input declares bounded server-authored request fields" do
      tool = definition("terminal_request_human_input")

      assert tool.parameters.required == [
               "workspace_id",
               "session",
               "pane",
               "request_id",
               "agent_session_id",
               "kind",
               "prompt"
             ]

      assert tool.parameters.properties.kind.enum == ["clarification", "direction", "blocker"]
      assert tool.parameters.properties.choices.maxItems == 4
      assert tool.metadata.mutation? == true
      assert tool.metadata.capabilities == [:terminal_metadata]
      refute :raw_terminal_input in Map.get(tool.metadata, :policy_tags, [])
    end

    test "file_open_in_pane requires workspace_id and path on the wire" do
      tool = definition("file_open_in_pane")

      assert tool.parameters.required == ["workspace_id", "path"]
      assert tool.parameters.properties.path.type == "string"
      assert tool.parameters.properties.line.type == "integer"
      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :medium
      assert :opens_file_surface in tool.metadata.policy_tags
    end

    test "diff_open is one-shot intent: workspace_id only, no placement props" do
      tool = definition("diff_open")

      assert tool.parameters.required == ["workspace_id"]
      assert tool.parameters.properties.path.type == "string"
      refute Map.has_key?(tool.parameters.properties, :placement)
      refute Map.has_key?(tool.parameters.properties, :pane_id)
      refute Map.has_key?(tool.parameters.properties, :size)
      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :low
      assert :surfaces_diff_viewport in tool.metadata.policy_tags
    end

    test "run_open is one-shot intent: workspace_id only, no placement props" do
      tool = definition("run_open")

      assert tool.parameters.required == ["workspace_id"]
      assert tool.parameters.properties.run_id.type == "string"
      refute Map.has_key?(tool.parameters.properties, :placement)
      refute Map.has_key?(tool.parameters.properties, :pane_id)
      refute Map.has_key?(tool.parameters.properties, :size)
      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :low
      assert :surfaces_run_viewport in tool.metadata.policy_tags
    end

    test "terminal_topology definition pins session as required on the wire" do
      topology = definition("terminal_topology")

      assert topology.parameters.required == ["session"]
      assert topology.parameters.properties.session.type == "string"
      assert topology.metadata.mutation? == false
      assert topology.metadata.capabilities == [:terminal_read]
    end

    test "orchestration_status is classified read-only metadata with required scope" do
      tool = definition("orchestration_status")

      assert tool.parameters.required == ["workspace_id", "session"]
      assert tool.parameters.properties.session.type == "string"
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
    end

    test "worker_status is classified read-only metadata with required pane scope" do
      tool = definition("worker_status")

      assert tool.parameters.required == ["workspace_id", "session", "pane"]
      assert tool.parameters.properties.pane.type == "string"
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
    end

    test "orchestration_list_workers is classified read-only metadata with required scope" do
      tool = definition("orchestration_list_workers")

      assert tool.parameters.required == ["workspace_id", "session"]
      assert tool.parameters.properties.session.type == "string"
      assert tool.parameters.properties.fleet_role.enum == ["manager", "worker"]
      assert tool.parameters.properties.needs_you_only.type == "boolean"
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
    end

    test "runtime_signal is classified read-only metadata (S11)" do
      tool = definition("runtime_signal")

      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
      refute "workspace_id" in (tool.parameters.required || [])
    end

    test "worker_launch is a medium mutation with required spawn scope" do
      tool = definition("worker_launch")

      assert tool.parameters.required == ["workspace_id", "session", "runtime", "task_slug"]

      assert tool.parameters.properties.runtime.enum == [
               "grok",
               "codex",
               "claude",
               "opencode",
               "agent"
             ]

      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :medium
      assert :terminal_mutation in tool.metadata.capabilities
    end

    test "worker_launch fails closed without required args" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("worker_launch", %{
                 "session" => "casein_ws-1_x",
                 "runtime" => "opencode",
                 "task_slug" => "x"
               })

      assert {:error, {:missing_argument, "runtime"}} =
               TerminalTools.invoke("worker_launch", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_x",
                 "task_slug" => "x"
               })
    end

    test "worker_cancel is a medium mutation with required pane scope" do
      tool = definition("worker_cancel")

      assert tool.parameters.required == ["workspace_id", "session", "pane"]
      assert tool.parameters.properties.pane.type == "string"
      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :medium
      assert :terminal_mutation in tool.metadata.capabilities
    end

    test "worker_cancel fails closed without required args" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("worker_cancel", %{
                 "session" => "casein_ws-1_x",
                 "pane" => "%42"
               })

      assert {:error, {:missing_argument, "pane"}} =
               TerminalTools.invoke("worker_cancel", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_x"
               })
    end

    test "worktree_status is classified read-only metadata with required pane scope" do
      tool = definition("worktree_status")

      assert tool.parameters.required == ["workspace_id", "session", "pane"]
      assert tool.parameters.properties.pane.type == "string"
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
    end

    test "worktree_status fails closed without required args" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("worktree_status", %{
                 "session" => "casein_ws-1_x",
                 "pane" => "%42"
               })

      assert {:error, {:missing_argument, "pane"}} =
               TerminalTools.invoke("worktree_status", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_x"
               })
    end

    test "worktree_changed_paths is classified read-only metadata with required pane scope" do
      tool = definition("worktree_changed_paths")

      assert tool.parameters.required == ["workspace_id", "session", "pane"]
      assert tool.parameters.properties.pane.type == "string"
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
    end

    test "worktree_changed_paths fails closed without required args" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("worktree_changed_paths", %{
                 "session" => "casein_ws-1_x",
                 "pane" => "%42"
               })

      assert {:error, {:missing_argument, "pane"}} =
               TerminalTools.invoke("worktree_changed_paths", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_x"
               })
    end

    test "worktree_diff is classified read-only metadata with required pane scope" do
      tool = definition("worktree_diff")

      assert tool.parameters.required == ["workspace_id", "session", "pane"]
      assert tool.parameters.properties.pane.type == "string"
      assert tool.metadata.mutation? == false
      assert tool.metadata.danger_level == :low
      assert :terminal_metadata in tool.metadata.capabilities
      assert :terminal_read in tool.metadata.capabilities
    end

    test "worktree_diff fails closed without required args" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("worktree_diff", %{
                 "session" => "casein_ws-1_x",
                 "pane" => "%42"
               })

      assert {:error, {:missing_argument, "pane"}} =
               TerminalTools.invoke("worktree_diff", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_x"
               })
    end

    test "terminal_send_command keeps high-danger mutation metadata" do
      tool = definition("terminal_send_command")

      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :high
      assert tool.metadata.policy_tags == [:raw_terminal_input]
      assert is_list(tool.metadata.examples)
    end

    test "clarification request is a bounded metadata mutation, not terminal input" do
      tool = definition("terminal_request_clarification")

      assert tool.parameters.required == [
               "workspace_id",
               "session",
               "pane",
               "request_id",
               "agent_session_id",
               "question"
             ]

      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :low
      assert tool.metadata.capabilities == [:terminal_metadata]
      refute :raw_terminal_input in Map.get(tool.metadata, :policy_tags, [])
    end
  end

  describe "invoke/2 validation" do
    test "terminal_topology rejects a missing session before tmux access" do
      assert {:error, {:missing_argument, "session"}} =
               TerminalTools.invoke("terminal_topology", %{"workspace_id" => "ws-1"})
    end

    test "orchestration_status fails closed without workspace_id or session" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("orchestration_status", %{"session" => "casein_ws-1_x"})

      assert {:error, {:missing_argument, "session"}} =
               TerminalTools.invoke("orchestration_status", %{"workspace_id" => "ws-1"})
    end

    test "worker_status fails closed without workspace_id, session, or pane" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("worker_status", %{
                 "session" => "casein_ws-1_x",
                 "pane" => "%3"
               })

      assert {:error, {:missing_argument, "session"}} =
               TerminalTools.invoke("worker_status", %{"workspace_id" => "ws-1", "pane" => "%3"})

      assert {:error, {:missing_argument, "pane"}} =
               TerminalTools.invoke("worker_status", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_x"
               })
    end

    test "orchestration_list_workers fails closed without workspace_id or session" do
      assert {:error, {:missing_argument, "workspace_id"}} =
               TerminalTools.invoke("orchestration_list_workers", %{
                 "session" => "casein_ws-1_x"
               })

      assert {:error, {:missing_argument, "session"}} =
               TerminalTools.invoke("orchestration_list_workers", %{"workspace_id" => "ws-1"})
    end

    test "terminal_send_keys rejects a non-string keys argument" do
      assert {:error, %{error: :invalid_argument, message: message}} =
               TerminalTools.invoke("terminal_send_keys", %{
                 "workspace_id" => "ws-1",
                 "session" => "casein_ws-1_default",
                 "keys" => 42
               })

      assert message =~ "keys"
    end

    test "unknown tools still return :unknown_tool" do
      assert {:error, :unknown_tool} =
               TerminalTools.invoke("terminal_not_a_tool", %{"workspace_id" => "ws-1"})
    end
  end

  describe "terminal_wait_agent_state timeout ceiling" do
    test "schema advertised maximum is the MCP-client-safe 25s ceiling" do
      tool = definition("terminal_wait_agent_state")
      timeout = tool.parameters.properties.timeout_ms

      assert timeout.maximum == 25_000
      assert timeout.description =~ "25000"
      assert timeout.description =~ ~r/30s|30 s/
      assert tool.description =~ "25000"
      assert tool.description =~ ~r/30s|30 s/
    end

    test "values above the ceiling clamp to the effective max" do
      alias Casein.Agents.TerminalTools.Helpers

      assert Helpers.clamp_wait_timeout_ms(55_000) == 25_000
      assert Helpers.clamp_wait_timeout_ms(25_000) == 25_000
      assert Helpers.clamp_wait_timeout_ms(nil) == 25_000
      assert Helpers.clamp_wait_timeout_ms(-1) == 0
    end
  end

  defp definition(name) do
    Enum.find(TerminalTools.definitions(), &(&1.name == name))
  end
end
