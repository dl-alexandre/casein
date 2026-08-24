defmodule Casein.Agents.TerminalTools.PasteAgentText do
  @moduledoc "terminal_paste_agent_text."

  use Jido.Action,
    name: "terminal_paste_agent_text",
    description:
      "Paste literal text through a tmux paste buffer. Omit pane to target the role-marked agent_pair pane; pass an explicit pane id to paste into that pane without requiring agent_pair (fleet worker briefs). On submit:true, Enter is pressed after the paste settles and confirmed via hook/transcript/screen — Enter is not retried; do not double-Enter yourself.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.1.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      text: [type: :string, required: true],
      submit: [type: :boolean],
      confirm: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param(),
          pane: Helpers.pane_param(),
          text: Helpers.paste_text_param(),
          submit: Helpers.submit_param(),
          confirm: Helpers.confirm_param()
        }),
        ["text"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_paste_agent_text")

  @impl Jido.Action
  def run(params, _context) do
    Agent.paste_agent_text(Helpers.to_impl_args(params))
  end
end
