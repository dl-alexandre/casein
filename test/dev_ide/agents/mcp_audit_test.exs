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
  alias DevIDE.Audit
  alias DevIDE.Audit.MemoryAdapter

  setup do
    prev_adapter = Application.get_env(:dev_ide, :audit_adapter)
    Application.put_env(:dev_ide, :audit_adapter, MemoryAdapter)
    MemoryAdapter.clear()

    on_exit(fn ->
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
end
