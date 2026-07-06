defmodule DevIDE.Agents.TerminalTools.Topology do
  @moduledoc "terminal_topology."

  use Jido.Action,
    name: "terminal_topology",
    description:
      "Inspect a session's structure: its windows and panes with geometry, the running command per pane, and which window/pane is active. Use this to find the agent pane id after applying the agent_pair template.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(Map.merge(Helpers.workspace_props(), %{session: Helpers.session_param()}), [
        "session"
      ])

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_topology")

  @impl Jido.Action
  def run(params, _context) do
    Impl.topology(Helpers.to_impl_args(params))
  end
end
