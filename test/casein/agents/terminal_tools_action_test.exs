defmodule Casein.Agents.TerminalToolsActionTest do
  @moduledoc """
  Unit tests for the Jido.Action-backed terminal tool surface.

  Pins tools/list wire shapes and ToolAction validation semantics while the
  legacy conn/contract suites stay unchanged.
  """
  use ExUnit.Case, async: true

  alias Casein.Agents.TerminalTools

  describe "definitions/0" do
    test "exposes 18 terminal tools plus annotation tools" do
      names = TerminalTools.definitions() |> Enum.map(& &1.name)

      assert length(names) == 20

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
            "terminal_send_keys",
            "terminal_send_command",
            "file_open_in_pane",
            "terminal_set_agent_label",
            "terminal_report_worktree",
            "terminal_report_agent_state",
            "terminal_wait_agent_state",
            "gate_report",
            "annotation_list",
            "annotation_propose"
          ] do
        assert expected in names
      end
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

    test "terminal_topology definition pins session as required on the wire" do
      topology = definition("terminal_topology")

      assert topology.parameters.required == ["session"]
      assert topology.parameters.properties.session.type == "string"
      assert topology.metadata.mutation? == false
      assert topology.metadata.capabilities == [:terminal_read]
    end

    test "terminal_send_command keeps high-danger mutation metadata" do
      tool = definition("terminal_send_command")

      assert tool.metadata.mutation? == true
      assert tool.metadata.danger_level == :high
      assert tool.metadata.policy_tags == [:raw_terminal_input]
      assert is_list(tool.metadata.examples)
    end
  end

  describe "invoke/2 validation" do
    test "terminal_topology rejects a missing session before tmux access" do
      assert {:error, {:missing_argument, "session"}} =
               TerminalTools.invoke("terminal_topology", %{"workspace_id" => "ws-1"})
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
