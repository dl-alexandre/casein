defmodule Casein.Agents.TerminalTools.Inbox do
  @moduledoc "terminal_inbox."

  use Jido.Action,
    name: "terminal_inbox",
    description:
      "Read messages other agents left for you with terminal_say, oldest first. Defaults to the caller pane plus any work handle attached there, so a successor that reattaches the handle still sees queued role mail. Each message carries honest lifecycle fields (#911): status queued|collected, unread?, stable message_id. Messages stay pending/unread until collect=true — collection clears unread, not sending. Double-collect is idempotent. Pass orphaned=true to list pane: mailboxes whose pane no longer exists. This is an addressed store agents collect from; it never writes into panes (no terminal_send_*). Poll when waiting on another agent rather than watching its pane.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.2.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      address: [type: :string],
      pane: [type: :string],
      collect: [type: :boolean],
      include_collected: [type: :boolean],
      orphaned: [type: :boolean],
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
            "Mailbox to read (handle:<id>, pane:%3, or worktree:/abs/path). Defaults to the " <>
              "caller pane plus any attached work handle."
        },
        pane: Helpers.pane_param(),
        collect: %{
          type: "boolean",
          description:
            "Mark the returned messages as collected/read. Leave false to peek: status stays " <>
              "queued and unread?=true. Collect is what clears unread — not sending. Defaults to false."
        },
        include_collected: %{
          type: "boolean",
          description:
            "When true, also return already-collected messages (status=collected, unread?=false). " <>
              "Default false returns only pending/queued."
        },
        orphaned: %{
          type: "boolean",
          description:
            "When true, list pane: mailboxes whose pane no longer exists instead of " <>
              "reading one mailbox. A queue nothing is listening to is a reportable condition."
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
