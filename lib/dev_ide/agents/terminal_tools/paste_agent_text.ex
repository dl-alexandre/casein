defmodule Casein.Agents.TerminalTools.PasteAgentText do
  @moduledoc "terminal_paste_agent_text."

  use Jido.Action,
    name: "terminal_paste_agent_text",
    description:
      "Paste literal text into the dedicated agent pane through a tmux paste buffer. Use this for multiline snippets, JSON, prompts, or code blocks. Requires the agent_pair marker and does not fall back to the operator pane.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      caller_pane: [type: :string],
      text: [type: :string, required: true],
      submit: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param(),
          text: Helpers.paste_text_param(),
          submit: Helpers.submit_param()
        }),
        ["text"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_paste_agent_text")

  @impl Jido.Action
  def run(params, _context) do
    Impl.paste_agent_text(Helpers.to_impl_args(params))
  end
end
