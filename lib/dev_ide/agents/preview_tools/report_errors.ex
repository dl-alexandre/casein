defmodule DevIDE.Agents.PreviewTools.ReportErrors do
  @moduledoc "preview_report_errors."

  use Jido.Action,
    name: "preview_report_errors",
    description: "Return console and network errors from the latest observation.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      session_id: [type: {:or, [:integer, :string]}, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.session_only()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_report_errors")

  @impl Jido.Action
  def run(params, _context) do
    Impl.report_errors(Helpers.to_impl_args(params))
  end
end
