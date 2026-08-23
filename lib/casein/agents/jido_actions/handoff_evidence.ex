defmodule Casein.Agents.JidoActions.HandoffEvidence do
  @moduledoc "Typed evidence handoff. Does not project cockpit state (#1016)."

  use Jido.Action,
    name: "handoff_evidence",
    description: "Record changed paths and a verification reference for the attempt.",
    category: "handoff",
    tags: ["handoff"],
    vsn: "1.0.0",
    schema: [
      paths: [type: {:list, :string}],
      summary: [type: :string],
      verification_ref: [type: :string]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.report("handoff_evidence", params, ctx)
end
