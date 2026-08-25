defmodule Casein.Agents.JidoActions.TaskCancel do
  @moduledoc "Typed `task_cancel` — not yet on the Code MCP contract."

  use Jido.Action,
    name: "task_cancel",
    description: "Cancel a durable long-running action handle.",
    category: "task",
    tags: ["task"],
    vsn: "1.0.0",
    schema: [
      handle_id: [type: :string]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(_params, ctx), do: Runner.unsupported("task_cancel", ctx)
end
