defmodule Casein.Agents.TerminalTools.Context do
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
      session: [type: :string],
      caller_pane: [type: :string]
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
          caller_pane: Helpers.caller_pane_param()
        })
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_context")

  @impl Jido.Action
  def run(params, _context) do
    Session.context(Helpers.to_impl_args(params))
  end
end
