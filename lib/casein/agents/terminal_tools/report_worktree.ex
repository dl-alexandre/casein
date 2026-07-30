defmodule Casein.Agents.TerminalTools.ReportWorktree do
  @moduledoc "terminal_report_worktree."

  use Jido.Action,
    name: "terminal_report_worktree",
    description:
      "Report an agent-created Git worktree so Casein can show it under the owning workspace. Call after creating or switching to a worktree, and again at session end with exit_status/handoff when work is not landing immediately. Requires workspace_id and worktree_path; optional fields include branch, agent, runner_id, session_id, tmux_session_id, ensure_preview_started (false by default), exit_status (landed|wip|handoff), and handoff (short status message).",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      worktree_path: [type: :string, required: true],
      branch: [type: :string],
      agent: [type: :string],
      runner_id: [type: :string],
      session_id: [type: :string],
      tmux_session_id: [type: :string],
      ensure_preview_started: [type: :boolean],
      exit_status: [type: :string],
      handoff: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Report}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          worktree_path: Helpers.worktree_path_param(),
          branch: Helpers.branch_param(),
          agent: Helpers.agent_param(),
          runner_id: Helpers.runner_id_param(),
          session_id: Helpers.session_id_param(),
          tmux_session_id: Helpers.tmux_session_id_param(),
          ensure_preview_started: Helpers.ensure_preview_started_param(),
          exit_status: Helpers.exit_status_param(),
          handoff: Helpers.handoff_param()
        }),
        ["workspace_id", "worktree_path"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_report_worktree")

  @impl Jido.Action
  def run(params, _context) do
    Report.report_worktree(Helpers.to_impl_args(params))
  end
end
