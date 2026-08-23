defmodule Casein.Agents.JidoActions.ReportProgress do
  @moduledoc "Typed progress handoff. Does not project cockpit state (#1016)."

  use Jido.Action,
    name: "report_progress",
    description: "Record a bounded progress summary for the current attempt.",
    category: "handoff",
    tags: ["handoff"],
    vsn: "1.0.0",
    schema: [
      summary: [type: :string, required: true]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.report("report_progress", params, ctx)
end
