defmodule Casein.Agents.TerminalTools.SendKeys do
  @moduledoc "terminal_send_keys."

  use Jido.Action,
    name: "terminal_send_keys",
    description:
      "Send raw keystrokes to a pane WITHOUT a trailing Enter. Use tmux key names for control keys (e.g. \"C-c\", \"Up\", \"Enter\"). Defaults to the active pane; pass `pane` to target the agent pane from terminal_topology. For running a shell command, prefer terminal_send_command.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string, required: true],
      keys: [type: :string, required: true],
      pane: [type: :string]
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
          keys: Helpers.keys_param(),
          pane: Helpers.pane_param()
        }),
        ["session", "keys"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_send_keys")

  @impl Jido.Action
  def run(params, _context) do
    Command.send_keys(Helpers.to_impl_args(params))
  end
end
