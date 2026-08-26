defmodule Casein.Agents.JidoActions.HandoffEvidence do
  @moduledoc "Typed evidence handoff. Projected by `Casein.Agents.JidoLifecycle`."

  use Jido.Action,
    name: "handoff_evidence",
    description:
      "Record changed paths, verification, and optional PR handoff metadata for the attempt.",
    category: "handoff",
    tags: ["handoff"],
    vsn: "1.0.0",
    schema: [
      paths: [type: {:list, :string}],
      summary: [type: :string],
      verification_ref: [type: :string],
      repository: [type: :string],
      pull_request: [type: :integer],
      head_sha: [type: :string],
      review_thread_ids: [type: {:list, :string}],
      handoff_target: [type: :string],
      review_resolution: [type: :string],
      merge_policy: [type: :string]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.report("handoff_evidence", params, ctx)
end
