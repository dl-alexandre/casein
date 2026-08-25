defmodule Casein.Agents.JidoActions.RequestHumanInput do
  @moduledoc "Typed headless human-input request. No pane or keystrokes."

  use Jido.Action,
    name: "request_human_input",
    description: "Block for a bounded human decision (clarification/direction/blocker).",
    category: "human",
    tags: ["human"],
    vsn: "1.0.0",
    schema: [
      request_id: [type: :string, required: true],
      kind: [type: :string, required: true],
      prompt: [type: :string, required: true],
      choices: [type: {:list, :string}]
    ]

  alias Casein.Agents.JidoActions.Runner

  @kinds ~w(clarification direction blocker)

  @impl Jido.Action
  def run(params, ctx) do
    if params.kind in @kinds do
      Runner.block_on_human("request_human_input", params, ctx)
    else
      {:error,
       %{
         error: :invalid_argument,
         message: "kind must be one of #{Enum.join(@kinds, ", ")}"
       }}
    end
  end
end
