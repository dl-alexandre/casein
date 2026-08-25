defmodule Casein.Agents.JidoActions.CodeExec do
  @moduledoc "Typed `code_exec` — allowlisted verifier via CodeTools. Not a shell."

  use Jido.Action,
    name: "code_exec",
    description: "Run a server-owned verifier in the assigned worktree.",
    category: "code",
    tags: ["code", "exec"],
    vsn: "1.0.0",
    schema: [
      command_id: [type: :string, required: true],
      extra_args: [type: {:list, :string}],
      cwd: [type: :string],
      timeout_ms: [type: :integer],
      max_output_bytes: [type: :integer]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx), do: Runner.forward_code("code_exec", params, ctx)
end
