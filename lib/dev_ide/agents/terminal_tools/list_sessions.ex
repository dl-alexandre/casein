defmodule DevIDE.Agents.TerminalTools.ListSessions do
  @moduledoc "terminal_list_sessions."

  use Jido.Action,
    name: "terminal_list_sessions",
    description:
      "List live DevIDE-managed tmux sessions (name, whether a client is attached, last activity). Start here to discover a session name to operate on. Pass `workspace_id` to scope to one workspace. Optional `contains` filters by substring.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      contains: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do: Tool.object(Map.merge(Helpers.workspace_props(), %{contains: Helpers.contains_param()}))

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_list_sessions")

  @impl Jido.Action
  def run(params, _context) do
    Impl.list_sessions(Helpers.to_impl_args(params))
  end
end
