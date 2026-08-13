defmodule Casein.Agents.TerminalTools.WorktreeStatus do
  @moduledoc "worktree_status."

  use Jido.Action,
    name: "worktree_status",
    description:
      "Read-only structured Git inspection for one worker pane (M4.2 #384): joins WorkerStatus identity with Git.Inspector (same inspector as casein://fleet/summary). Returns worktree_path plus git.inspect_state, branch, HEAD, upstream, ahead/behind, commits_not_on_origin?. inspect_state unknown never means clean or not-ahead. No scrollback, no shell, no mutations. changed_paths / worker_replace / durable graphs remain out of scope. Requires workspace_id, session, and pane.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      pane: [type: :string, required: true],
      caller_pane: [type: :string],
      window_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Session}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          pane: Helpers.pane_param(),
          caller_pane: Helpers.caller_pane_param(),
          window_id: %{
            type: "string",
            description: "Optional tmux window id to disambiguate the target pane."
          }
        }),
        ["workspace_id", "session", "pane"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("worktree_status")

  @impl Jido.Action
  def run(params, _context) do
    Session.worktree_status(Helpers.to_impl_args(params))
  end
end
