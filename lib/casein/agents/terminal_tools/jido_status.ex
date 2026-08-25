defmodule Casein.Agents.TerminalTools.JidoStatus do
  @moduledoc "jido_status."

  use Jido.Action,
    name: "jido_status",
    description:
      "Read-only status and redacted result for one headless Jido attempt. Requires workspace_id and attempt_id. No pane, no scrollback, no shell. Missing attempts return not_found.",
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
  def mcp_metadata, do: Helpers.metadata("jido_status")

  @impl Jido.Action
  def run(params, _context) do
    JidoDelegate.status(Helpers.to_impl_args(params))
  end
end
