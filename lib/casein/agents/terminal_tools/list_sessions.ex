defmodule Casein.Agents.TerminalTools.ListSessions do
  @moduledoc "terminal_list_sessions."

  use Jido.Action,
    name: "terminal_list_sessions",
    description:
      "List live Casein-managed tmux sessions with stable alias, workspace path, pane-role, and operator/agent identity metadata. A session-scoped MCP URL injects an exact session and returns only that session; otherwise ambiguity stays fail-closed. Optional `contains` filters by substring.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.1.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      contains: [type: :string],
      allow_cross_workspace: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Session}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          contains: Helpers.contains_param()
        })
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_list_sessions")

  @impl Jido.Action
  def run(params, _context) do
    Session.list_sessions(Helpers.to_impl_args(params))
  end
end
