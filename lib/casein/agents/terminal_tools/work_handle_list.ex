defmodule Casein.Agents.TerminalTools.WorkHandleList do
  @moduledoc "terminal_work_handle_list."

  use Jido.Action,
    name: "terminal_work_handle_list",
    description:
      "List durable work handles for a workspace. Each entry includes the current pane binding (if any) and recorded status (source=recorded). Handles outlive pane respawn; unbound handles still appear until explicitly replaced.",
    category: "terminal",
    tags: ["terminal", "work_handle"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do: Tool.object(Helpers.workspace_props(), ["workspace_id"])

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_work_handle_list")

  @impl Jido.Action
  def run(params, _context) do
    Agent.work_handle_list(Helpers.to_impl_args(params))
  end
end
