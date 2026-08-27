defmodule Casein.Agents.JidoActions.GitHandoff do
  @moduledoc "Audited commit/push handoff for the assigned Workcell branch."

  use Jido.Action,
    name: "git_handoff",
    description:
      "Stage explicit allowlisted files, create a policy-checked commit, and push only the assigned branch. Does not create or merge a PR.",
    category: "handoff",
    tags: ["git", "handoff", "mutation"],
    vsn: "1.0.0",
    schema: [
      receipt_id: [type: :string, required: true],
      handoff_id: [type: :string, required: true],
      message: [type: :string, required: true],
      paths: [type: {:list, :string}, required: true],
      tests: [type: {:list, :map}],
      evidence_ref: [type: :string],
      decision_id: [type: :string]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.git_handoff(params, ctx)
end
