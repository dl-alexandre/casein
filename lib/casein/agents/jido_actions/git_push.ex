defmodule Casein.Agents.JidoActions.GitPush do
  @moduledoc "Typed worker push and PR handoff receipt. Never merges a pull request."

  use Jido.Action,
    name: "git_push",
    description:
      "Push the verified worker branch and hand its exact commit to Dash for PR completion.",
    category: "handoff",
    tags: ["git", "handoff"],
    vsn: "1.0.0",
    schema: [
      handoff: [type: :map, required: true],
      remote: [type: :string]
    ]

  alias Casein.Agents.GitTools

  @impl Jido.Action
  def run(params, ctx), do: GitTools.push_handoff(params, ctx)
end
