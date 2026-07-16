defmodule DevIDE.Agents.TerminalToolsGateReportTest do
  use DevIDE.TestCase, async: false

  alias DevIDE.Agents.Activity
  alias DevIDE.Agents.MCPAudit
  alias DevIDE.Agents.TerminalTools
  alias DevIDE.Audit

  setup do
    Audit.clear()
    Activity.clear()

    on_exit(fn ->
      Audit.clear()
      Activity.clear()
    end)

    :ok
  end

  test "a passing run records a gate.passed audit row with run details" do
    assert {:ok, result} =
             TerminalTools.invoke("gate_report", %{
               "workspace_id" => "ws-gate",
               "passed" => true,
               "branch" => "master",
               "sha" => "abc1234",
               "duration_s" => 412
             })

    assert result.action == "gate.passed"
    assert result.recorded

    assert [event] = Enum.filter(Audit.recent_for("ws-gate", 10), &(&1.action == "gate.passed"))
    assert event.actor_id == "pre_push_gate"
    assert event.source == "gate"
    assert event.target_type == "git_sha"
    assert event.target_ref == "abc1234"
    assert event.metadata.branch == "master"
    assert event.metadata.duration_s == 412
    refute Map.has_key?(event.metadata, :failed_step)
  end

  test "a failing run records gate.failed with the redacted failed step" do
    assert {:ok, %{action: "gate.failed"}} =
             TerminalTools.invoke("gate_report", %{
               "workspace_id" => "ws-gate",
               "passed" => false,
               "duration_s" => 33,
               "failed_step" => "running tests token=super-secret"
             })

    assert [event] = Enum.filter(Audit.recent_for("ws-gate", 10), &(&1.action == "gate.failed"))
    assert event.metadata.failed_step =~ "running tests"
    assert event.metadata.failed_step =~ "token=[REDACTED]"
    refute event.metadata.failed_step =~ "super-secret"
  end

  test "workspace_id and passed are both required" do
    assert {:error, _reason} = TerminalTools.invoke("gate_report", %{"passed" => true})

    assert {:error, _reason} = TerminalTools.invoke("gate_report", %{"workspace_id" => "ws-gate"})

    assert Audit.recent_for("ws-gate", 10) == []
  end

  test "gate_report is a mutation of record in the MCP audit layer" do
    :ok = MCPAudit.record_terminal("gate_report", %{"workspace_id" => "ws-gate"}, :ok)

    assert Enum.any?(
             Audit.recent_for("ws-gate", 10),
             &(&1.action == "agent.terminal_gate_report" and &1.source == "terminal_mcp")
           )
  end

  test "gate_report is advertised with its wire schema" do
    tool = Enum.find(TerminalTools.definitions(), &(&1.name == "gate_report"))

    assert tool, "expected gate_report in the terminal tool definitions"
    assert tool.parameters.required == ["workspace_id", "passed"]
    assert tool.parameters.properties.passed.type == "boolean"
    assert tool.parameters.properties.duration_s.type == "number"
    assert tool.metadata.mutation? == true
    assert tool.metadata.danger_level == :low
  end
end
