defmodule Casein.Agents.TerminalTools.Say do
  @moduledoc "terminal_say."

  use Jido.Action,
    name: "terminal_say",
    description:
      "Leave a message for another agent at an address instead of typing into its pane. Prefer this over terminal_send_agent_command for agent-to-agent messages: keystrokes race whatever the recipient's TUI is drawing, land silently in the wrong pane, and cannot tell you whether the message was ever read. The recipient collects with terminal_inbox when it is ready. `to` accepts a canonical address (handle:<id> for a durable role that survives pane respawn, pane:%3, worktree:/abs/path), an exact pane id, or a window name — a name matching more than one agent window is refused with its candidates rather than delivered to a guess. A pane: address whose pane does not exist is refused. Pass a stable message_id so a retry coalesces instead of sending twice.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      to: [type: :string, required: true],
      body: [type: :string, required: true],
      message_id: [type: :string],
      from_pane: [type: :string]
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
        to: %{
          type: "string",
          minLength: 1,
          maxLength: 512,
          description:
            "Recipient: a canonical address (handle:<id>, pane:%3, or worktree:/abs/path), " <>
              "an exact pane id, or a window name. Prefer handle: for long-lived roles. " <>
              "Ambiguous names and dead pane: addresses are refused, not delivered."
        },
        body: %{
          type: "string",
          minLength: 1,
          maxLength: 4_000,
          description: "Message text. Stored as operator content, never copied into MCP audit."
        },
        message_id: %{
          type: "string",
          minLength: 1,
          maxLength: 240,
          description: "Stable opaque id so a retried send coalesces instead of duplicating."
        },
        from_pane: Helpers.pane_param()
      }),
      ["workspace_id", "to", "body"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_say")

  @impl Jido.Action
  def run(params, _context), do: Agent.say(Helpers.to_impl_args(params))
end
