defmodule Casein.Agents.TerminalTools.ListSessions do
  @moduledoc "terminal_list_sessions."

  use Jido.Action,
    name: "terminal_list_sessions",
    description:
      "List live Casein-managed tmux sessions (name, whether a client is attached, last activity). Start here to discover a session name to operate on. Pass `workspace_id` to scope to one workspace. Optional `contains` filters by substring.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      contains: [type: :string],
      allow_cross_workspace: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Session}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do: Tool.object(Map.merge(Helpers.workspace_props(), %{contains: Helpers.contains_param()}))

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_list_sessions")

  @impl Jido.Action
  def run(params, _context) do
    Session.list_sessions(Helpers.to_impl_args(params))
  end
end
