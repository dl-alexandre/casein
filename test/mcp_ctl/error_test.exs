defmodule McpCtl.ErrorTest do
  use Casein.TestCase, async: true

  alias McpCtl.Error

  test "format/1 normalizes atom errors" do
    assert %{"error" => "session_not_found"} = Error.format(:session_not_found)
  end

  test "tool_result/1 returns MCP error envelope" do
    result = Error.tool_result(:origin_not_allowed)

    assert result.isError
    assert result.structuredContent["error"] == "origin_not_allowed"
  end
end
