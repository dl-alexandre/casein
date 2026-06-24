defmodule McpCtl.ToolTest do
  use ExUnit.Case, async: true

  alias McpCtl.Tool

  test "define/3 remains backward compatible" do
    assert %{
             name: "example",
             description: "Example tool",
             parameters: %{type: "object"}
           } = Tool.define("example", "Example tool", %{type: "object"})
  end

  test "define/4 stores metadata and public_metadata returns JSON-safe values" do
    tool =
      Tool.define("example", "Example tool", %{type: "object"}, %{
        mutation?: true,
        danger_level: :high,
        capabilities: [:terminal_mutation],
        policy_tags: [:raw_terminal_input],
        recovery_hints: ["Capture output after running."],
        examples: [%{arguments: %{"command" => "mix test"}}]
      })

    assert tool.metadata[:mutation?] == true

    assert Tool.public_metadata(tool) == %{
             "mutation" => true,
             "danger_level" => "high",
             "capabilities" => ["terminal_mutation"],
             "policy_tags" => ["raw_terminal_input"],
             "recovery_hints" => ["Capture output after running."],
             "examples" => [%{"arguments" => %{"command" => "mix test"}}]
           }
  end
end
