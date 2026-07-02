defmodule McpCtl.SchemaTest do
  use DevIDE.TestCase, async: true

  alias McpCtl.Schema

  test "workspace_object includes preview workspace id by default" do
    schema = Schema.workspace_object()

    assert schema[:properties][:workspace_id][:description] =~ "pre-scoped"
    refute Map.has_key?(schema[:properties], :workspace_path)
  end

  test "workspace_object supports terminal variant and optional path" do
    schema =
      Schema.workspace_object(variant: :terminal, include_path: true, required: [:workspace_id])

    assert schema[:properties][:workspace_id][:description] =~ "Scopes session discovery"
    assert schema[:properties][:workspace_path][:type] == "string"
    assert schema[:required] == [:workspace_id]
  end

  test "workspace_path_param describes folder resolution" do
    param = Schema.workspace_path_param()
    assert param[:type] == "string"
    assert param[:description] =~ "folder:"
  end

  test "merge_workspace_properties adds tool-specific fields" do
    base = Schema.workspace_object()
    merged = Schema.merge_workspace_properties(base, %{session: %{type: "string"}})

    assert merged[:properties][:session][:type] == "string"
    assert merged[:properties][:workspace_id]
  end

  test "merge_workspace_properties tolerates missing properties key" do
    merged = Schema.merge_workspace_properties(%{type: "object"}, %{pane: %{type: "string"}})
    assert merged[:properties][:pane][:type] == "string"
  end
end
