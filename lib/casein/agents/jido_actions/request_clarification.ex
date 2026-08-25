defmodule Casein.Agents.JidoActions.RequestClarification do
  @moduledoc "Typed headless clarification request. No pane or keystrokes."

  use Jido.Action,
    name: "request_clarification",
    description: "Ask the operator one bounded clarification question and block.",
    category: "human",
    tags: ["human"],
    vsn: "1.0.0",
    schema: [
      request_id: [type: :string, required: true],
      question: [type: :string, required: true]
    ]

  alias Casein.Agents.JidoActions.Runner

  @impl Jido.Action
  def run(params, ctx) do
    Runner.block_on_human("request_clarification", Map.put(params, :kind, "clarification"), ctx)
  end
end
