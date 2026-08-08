defmodule Casein.Agents.TerminalTools.SetNextPrompt do
  @moduledoc "terminal_set_next_prompt."

  use Jido.Action,
    name: "terminal_set_next_prompt",
    description:
      "Leave one sticky operator message for an agent pane, delivered on its next state edge instead of mid-turn. At most one message is pending per pane: setting another replaces it (latest wins) — this is not a queue. Delivers immediately when the pane is already in the requested state, and drops the message if the runtime session changes or the pane dies. Use this instead of terminal_paste_agent_text when the target agent is busy.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      text: [type: :string, required: true],
      deliver_when: [type: :string],
      coalesce_key: [type: :string],
      agent_session_id: [type: :string],
      expires_in_seconds: [type: :integer],
      actor_id: [type: :string]
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
          text: Helpers.next_prompt_text_param(),
          deliver_when: Helpers.deliver_when_param(),
          coalesce_key: Helpers.coalesce_key_param(),
          agent_session_id: Helpers.agent_session_id_param(),
          expires_in_seconds: Helpers.expires_in_seconds_param(),
          actor_id: Helpers.actor_id_param()
        }),
        ["workspace_id", "text"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_set_next_prompt")

  @impl Jido.Action
  def run(params, _context) do
    Agent.set_next_prompt(Helpers.to_impl_args(params))
  end
end
