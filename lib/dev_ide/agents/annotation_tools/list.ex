defmodule DevIDE.Agents.AnnotationTools.List do
  @moduledoc "annotation_list: workspace annotations with optional filters."

  use Jido.Action,
    name: "annotation_list",
    description:
      "List workspace annotations. Filter by approval_state (pending, approved, " <>
        "rejected), file_path, session_id, or pane_id.",
    category: "annotation",
    tags: ["annotation"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [],
      limit: [type: {:or, [:integer, :string]}],
      approval_state: [type: :string],
      file_path: [type: :string],
      session_id: [type: :string],
      pane_id: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.AnnotationTools.{Helpers, Impl}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.list_parameters()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("annotation_list")

  @impl Jido.Action
  def run(params, _context) do
    Impl.list(Helpers.to_impl_args(params))
  end
end