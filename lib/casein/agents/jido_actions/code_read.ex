defmodule Casein.Agents.JidoActions.CodeRead do
  @moduledoc "Typed `code_read` — bounded file/range read via CodeTools."

  use Jido.Action,
    name: "code_read",
    description: "Read a repository-relative file from the assigned worktree.",
    category: "code",
    tags: ["code", "read"],
    vsn: "1.0.0",
    schema: [
      path: [type: :string, required: true],
      start_line: [type: :integer],
      end_line: [type: :integer],
      max_bytes: [type: :integer]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.forward_code("code_read", params, ctx)
end
