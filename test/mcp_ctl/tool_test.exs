defmodule McpCtl.ToolTest do
  use DevIDE.TestCase, async: true

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

  test "mcp_spec emits standard safety annotations and structured output schema" do
    tool =
      Tool.define("remove_preview", "Remove a preview", Tool.object(%{}), %{
        mutation?: true,
        danger_level: :high,
        idempotent_hint: true,
        output_schema: %{type: "object", required: ["removed"]}
      })

    assert %{
             inputSchema: %{type: "object"},
             outputSchema: %{type: "object", required: ["removed"]},
             annotations: %{
               readOnlyHint: false,
               destructiveHint: true,
               idempotentHint: true,
               openWorldHint: false
             }
           } = Tool.mcp_spec(tool)

    refute Map.has_key?(Tool.mcp_spec(tool).metadata, "output_schema")
    refute Map.has_key?(Tool.mcp_spec(tool).metadata, "idempotent_hint")
  end
end
