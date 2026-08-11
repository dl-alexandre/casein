defmodule Casein.Agents.TerminalTools.WorkHandleGet do
  @moduledoc "terminal_work_handle_get."

  use Jido.Action,
    name: "terminal_work_handle_get",
    description:
      "Resolve a durable work handle to the pane currently serving it and its recorded status. Status comes from AgentState / handle fields (source=recorded), never from scraping the pane title or scrollback. Returns unknown_handle when the id is missing.",
    category: "terminal",
    tags: ["terminal", "work_handle"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      handle_id: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          handle_id: %{
            type: "string",
            description: "Durable work handle id returned by terminal_work_handle_create."
          }
        }),
        ["workspace_id", "handle_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_work_handle_get")

  @impl Jido.Action
  def run(params, _context) do
    Agent.work_handle_get(Helpers.to_impl_args(params))
  end
end
