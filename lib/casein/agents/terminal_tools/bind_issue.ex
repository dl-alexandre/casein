defmodule Casein.Agents.TerminalTools.BindIssue do
  @moduledoc "terminal_bind_issue."

  use Jido.Action,
    name: "terminal_bind_issue",
    description:
      "Bind the GitHub issue this pane is working to the pane, so Casein chrome and terminal_topology show issue:#N. Call it right after claiming a queue/* issue (see the claim protocol in AGENTS.md), and call it again with no issue to release when the work lands. Defaults to the dedicated agent pane when pane is omitted. Accepts 678, \"#678\" or a full issue URL. The binding is cleared automatically when the pane closes, so it can never outlive the agent that claimed the issue. Refuses when the issue is already bound to another live pane in the same workspace (structured issue_already_bound with holder pane_id, window_id, issue). Pass allow_duplicate: true to record both holders.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      caller_pane: [type: :string],
      pane: [type: :string],
      issue: [type: :string],
      url: [type: :string],
      title: [type: :string],
      allow_duplicate: [type: :boolean]
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
          issue: %{
            type: "string",
            description:
              "Issue to bind: 678, \"#678\" or a full issue URL. Omit (or pass null) to clear the binding."
          },
          url: %{type: "string", description: "Issue URL, shown in chrome when present."},
          title: %{type: "string", description: "Issue title, for display."},
          allow_duplicate: Helpers.allow_duplicate_param()
        }),
        ["workspace_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_bind_issue")

  @impl Jido.Action
  def run(params, _context) do
    Agent.bind_issue(Helpers.to_impl_args(params))
  end
end
