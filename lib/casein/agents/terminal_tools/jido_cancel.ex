defmodule Casein.Agents.TerminalTools.JidoCancel do
  @moduledoc "jido_cancel."

  use Jido.Action,
    name: "jido_cancel",
    description:
      "Cancel a headless Jido attempt. Requires workspace_id and attempt_id. Does not kill tmux panes or other workspace attempts. Already-terminal attempts return already_terminal.",
    category: "terminal",
    tags: ["terminal", "orchestration", "jido"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      attempt_id: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.JidoDelegate
  alias Casein.Agents.TerminalTools.Helpers
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          attempt_id: %{
            type: "string",
            description: "Attempt id returned by jido_admit."
          }
        }),
        ["workspace_id", "attempt_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("jido_cancel")

  @impl Jido.Action
  def run(params, _context) do
    JidoDelegate.cancel(Helpers.to_impl_args(params))
  end
end
