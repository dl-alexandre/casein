defmodule Casein.Agents.JidoActions.CodeApplyPatch do
  @moduledoc "Typed `code_apply_patch` — validated unified-diff apply via CodeTools."

  use Jido.Action,
    name: "code_apply_patch",
    description: "Apply a validated unified diff inside the assigned worktree.",
    category: "code",
    tags: ["code", "mutation"],
    vsn: "1.0.0",
    schema: [
      patch: [type: :string, required: true],
      idempotency_key: [type: :string]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.forward_code("code_apply_patch", params, ctx)
end
