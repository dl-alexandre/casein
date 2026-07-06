defmodule DevIDE.Agents.TerminalTools.Context do
  @moduledoc "terminal_context."

  use Jido.Action,
    name: "terminal_context",
    description:
      "Return the recommended terminal workflow for this workspace: matching sessions, the best session to inspect, whether the agent_pair pane is safe to mutate, and the exact next tool/arguments to call. Start here when an agent is not sure which session or pane to use.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do: Tool.object(Map.merge(Helpers.workspace_props(), %{session: Helpers.session_param()}))

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_context")

  @impl Jido.Action
  def run(params, _context) do
    Impl.context(Helpers.to_impl_args(params))
  end
end
