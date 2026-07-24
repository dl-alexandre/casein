defmodule DevIDE.Agents.TerminalTools.AgentTranscript do
  @moduledoc "terminal_agent_transcript."

  use Jido.Action,
    name: "terminal_agent_transcript",
    description:
      "Read the agent pane's live CLI transcript (lossless JSONL, not tmux scrollback). Uses the transcript_path reported by supported agent hooks (Claude or Grok) on the target pane. Returns normalized entries (role, text, tool calls, timestamps) plus a cursor for incremental pulls via since. Defaults to the last 30 entries.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      since: [type: :string],
      tail: [type: :integer],
      full_text: [type: :boolean]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          caller_pane: Helpers.caller_pane_param(),
          pane: Helpers.pane_param(),
          since: Helpers.since_param(),
          tail: Helpers.tail_param(),
          full_text: Helpers.full_text_param()
        })
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_agent_transcript")

  @impl Jido.Action
  def run(params, _context) do
    Agent.agent_transcript(Helpers.to_impl_args(params))
  end
end
