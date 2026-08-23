defmodule Casein.Agents.JidoActions.ReportResult do
  @moduledoc "Typed result handoff. Projected by `Casein.Agents.JidoLifecycle`."

  use Jido.Action,
    name: "report_result",
    description: "Record the attempt result without exposing unrelated history.",
    category: "handoff",
    tags: ["handoff"],
    vsn: "1.0.0",
    schema: [
      status: [type: :string, required: true],
      summary: [type: :string]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.report("report_result", params, ctx)
end
