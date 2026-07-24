defmodule Casein.Labels.DerivationTest do
  use Casein.TestCase, async: true

  alias Casein.Labels.Derivation

  test "derives mix command labels" do
    assert Derivation.from_mcp("terminal_send_agent_command", %{"command" => "mix test"}, :ok) ==
             "mix test"
  end

  test "derives annotation labels and truncates long content" do
    long = String.duplicate("a", 80)

    assert Derivation.from_mcp("annotation_propose", %{"content" => long}, :ok) ==
             String.slice(long, 0, 47) <> "…"
  end

  test "derives preview localhost labels" do
    assert Derivation.from_mcp(
             "preview_open_localhost",
             %{"port" => 5173, "path" => "/dashboard"},
             :ok
           ) == ":5173/dashboard"
  end

  test "ignores failed MCP calls" do
    assert Derivation.from_mcp(
             "terminal_send_command",
             %{"command" => "mix test"},
             {:error, :boom}
           ) ==
             nil
  end

  test "normalizes agent-provided labels" do
    assert Derivation.from_agent_label("  Refactor session handoff\n\n") ==
             "Refactor session handoff"
  end
end
