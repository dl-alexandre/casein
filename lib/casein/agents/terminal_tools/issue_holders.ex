defmodule Casein.Agents.TerminalTools.IssueHolders do
  @moduledoc "terminal_issue_holders."

  use Jido.Action,
    name: "terminal_issue_holders",
    description:
      "Read-only lookup of live panes bound to a GitHub issue in this workspace. One call answers who holds #N (pane_id, window_id, session). Dead-pane bindings are dropped first, so a gone pane never looks like a live holder. Requires workspace_id and issue.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      issue: [type: :string, required: true]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          issue: %{
            type: "string",
            description: "Issue to look up: 678, \"#678\" or a full issue URL."
          }
        }),
        ["workspace_id", "issue"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_issue_holders")

  @impl Jido.Action
  def run(params, _context) do
    Agent.issue_holders(Helpers.to_impl_args(params))
  end
end
