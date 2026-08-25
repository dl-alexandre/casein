defmodule Casein.Agents.TerminalTools.SendCommand do
  @moduledoc "terminal_send_command."

  use Jido.Action,
    name: "terminal_send_command",
    description:
      "Type a shell command into a pane and press Enter. Target the agent pane from terminal_topology — do not use the operator's focused pane. Confirms the submit landed (hook/transcript/screen) unless confirm:false. Unconfirmed submits return submit_not_confirmed — Enter is not retried. Read the result afterward with terminal_capture. A git command that would write a worktree another pane is also working in is refused (shared_worktree_mutation); pass allow_shared_worktree when the sharing is deliberate. The write receipt includes `input_buffer` (`has_content`, `source`: empty|placeholder|typed|unknown); `placeholder` is a suggested prompt, not unsent user text.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.1.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string, required: true],
      command: [type: :string, required: true],
      pane: [type: :string],
      confirm: [type: :boolean],
      allow_shared_worktree: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Command}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          command: Helpers.command_param(),
          pane: Helpers.pane_param(),
          confirm: Helpers.confirm_param(),
          allow_shared_worktree: Helpers.allow_shared_worktree_param()
        }),
        ["session", "command"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_send_command")

  @impl Jido.Action
  def run(params, _context) do
    Command.send_command(Helpers.to_impl_args(params))
  end
end
