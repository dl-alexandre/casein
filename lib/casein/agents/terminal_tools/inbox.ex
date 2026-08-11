defmodule Casein.Agents.TerminalTools.Inbox do
  @moduledoc "terminal_inbox."

  use Jido.Action,
    name: "terminal_inbox",
    description:
      "Read messages other agents left for you with terminal_say, oldest first. Defaults to your own pane's address, so an agent can simply call it with no arguments. Messages stay in the mailbox until collected: pass collect=true once you have acted on them, which is what makes 'sent but never read' a visible state rather than an assumption. Poll this when you are waiting on another agent rather than watching its pane.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      address: [type: :string],
      pane: [type: :string],
      collect: [type: :boolean],
      limit: [type: :integer]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(Helpers.workspace_props(), %{
        session: Helpers.session_param(),
        caller_pane: Helpers.caller_pane_param(),
        address: %{
          type: "string",
          maxLength: 512,
          description:
            "Mailbox to read (pane:%3 or worktree:/abs/path). Defaults to the caller pane's " <>
              "own address."
        },
        pane: Helpers.pane_param(),
        collect: %{
          type: "boolean",
          description:
            "Mark the returned messages as read. Leave false to peek without collecting; " <>
              "an uncollected message stays visible as one nobody acted on. Defaults to false."
        },
        limit: %{
          type: "integer",
          minimum: 1,
          maximum: 200,
          description: "Maximum messages to return (default 50)."
        }
      }),
      ["workspace_id"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_inbox")

  @impl Jido.Action
  def run(params, _context), do: Agent.inbox(Helpers.to_impl_args(params))
end
