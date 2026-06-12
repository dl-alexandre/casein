defmodule DevIDE.Agents.MCPErrorTest do
  use ExUnit.Case, async: true

  alias DevIDE.Agents.MCPError

  test "format/1 maps workspace_not_found maps with string keys" do
    reason = %{
      error: :workspace_not_found,
      workspace_id: "ws-missing",
      message: "Workspace not found"
    }

    assert %{"error" => "workspace_not_found", "workspace_id" => "ws-missing"} =
             MCPError.format(reason)
  end

  test "format/1 maps ambiguous_workspace_sessions" do
    reason = %{
      error: :ambiguous_workspace_sessions,
      ambiguous: true,
      candidate_sessions: [%{session: "devide_alpha_a", activity: 1}]
    }

    formatted = MCPError.format(reason)
    assert formatted["ambiguous"] == true
    assert [%{"session" => "devide_alpha_a"}] = formatted["candidate_sessions"]
  end

  test "format/1 maps atom errors" do
    assert %{"error" => "not_found", "message" => "not_found"} = MCPError.format(:not_found)
  end

  test "format/1 maps binary tmux stderr" do
    assert %{"error" => "tool_error", "message" => "pane not found"} =
             MCPError.format("pane not found")
  end

  test "format/1 maps missing_argument tuples" do
    assert %{"error" => "missing_argument", "argument" => "session"} =
             MCPError.format({:missing_argument, "session"})
  end

  test "format/1 maps redirect_blocked tuples from PreviewControl" do
    location = "http://169.254.169.254/latest/meta-data/"

    assert %{
             "error" => "redirect_blocked",
             "status" => 302,
             "location" => ^location,
             "message" => message
           } = MCPError.format({:redirect_blocked, 302, location})

    assert message =~ "302"
    assert message =~ location
  end

  test "format/1 maps http_status tuples from PreviewControl" do
    assert %{"error" => "http_status", "status" => 401, "body" => "Not authenticated"} =
             MCPError.format({:http_status, 401, "Not authenticated"})
  end

  test "format/1 maps other 3-tuple atom tags" do
    assert %{"error" => "custom_error", "details" => %{"a" => "x", "b" => "y"}} =
             MCPError.format({:custom_error, "x", "y"})
  end

  test "tool_result/1 round-trips through JSON" do
    result = MCPError.tool_result({:redirect_blocked, 301, "http://evil.example/"})

    assert %{isError: true, structuredContent: structured} = result
    assert structured["error"] == "redirect_blocked"

    encoded = Jason.encode!(structured)
    assert %{"error" => "redirect_blocked", "status" => 301} = Jason.decode!(encoded)
  end
end
