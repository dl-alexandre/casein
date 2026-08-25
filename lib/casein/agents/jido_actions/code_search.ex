defmodule Casein.Agents.JidoActions.CodeSearch do
  @moduledoc "Typed `code_search` — bounded worktree search via CodeTools."

  use Jido.Action,
    name: "code_search",
    description: "Search text in the assigned worktree with explicit caps.",
    category: "code",
    tags: ["code", "search"],
    vsn: "1.0.0",
    schema: [
      query: [type: :string, required: true],
      path: [type: :string],
      glob: [type: :string],
      max_matches: [type: :integer],
      max_bytes: [type: :integer]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.forward_code("code_search", params, ctx)
end
