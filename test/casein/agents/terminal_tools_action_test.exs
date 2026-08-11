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

      assert length(names) == 32

      for expected <- [
            "terminal_list_sessions",
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
            "file_open_in_pane",
            "diff_open",
            "run_open",
            "terminal_set_agent_label",
            "terminal_report_worktree",
            "terminal_report_agent_state",
            "terminal_wait_agent_state",
            "orchestration_status",
            "worker_status",
            "gate_report",
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

  defp definition(name) do
    Enum.find(TerminalTools.definitions(), &(&1.name == name))
  end
end
