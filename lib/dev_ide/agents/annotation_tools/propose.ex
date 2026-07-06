defmodule DevIDE.Agents.AnnotationTools.Propose do
  @moduledoc "annotation_propose: pending annotation for human review."

  use Jido.Action,
    name: "annotation_propose",
    description:
      "Propose an annotation for human review (defaults to pending approval). " <>
        "Must include content, author_type, and at least one context anchor " <>
        "(file_path, terminal_range, preview_id, or linked_entities).",
    category: "annotation",
    tags: ["annotation"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [],
      content: [type: :string],
      author_type: [type: :string],
      visibility: [type: :string],
      session_id: [type: :string],
      pane_id: [type: :string],
      preview_id: [type: :string],
      file_path: [type: :string],
      file_range: [],
      terminal_range: [],
      linked_entities: [],
      metadata: [],
      actor_id: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.AnnotationTools.{Helpers, Impl}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.propose_parameters()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("annotation_propose")

  @impl Jido.Action
  def run(params, _context) do
    Impl.propose(Helpers.to_impl_args(params))
  end
end