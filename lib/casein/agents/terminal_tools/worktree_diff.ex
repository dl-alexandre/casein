defmodule Casein.Agents.TerminalTools.WorktreeDiff do
  @moduledoc "worktree_diff."

  use Jido.Action,
    name: "worktree_diff",
    description:
      "Read-only bounded unified diff for one worker pane (M4.4 #384): joins WorkerStatus identity with git diff HEAD (staged+unstaged vs HEAD). Returns status_state, diff, byte_count, truncated?. status_state unknown never emits diff: \"\" — operators treat empty as proof the tree matches HEAD. No arbitrary command, no path-contract language, no scrollback, no mutations. path contracts / worker_replace / durable graphs remain out of scope. Requires workspace_id, session, and pane.",
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
  def mcp_metadata, do: Helpers.metadata("worktree_diff")

  @impl Jido.Action
  def run(params, _context) do
    Session.worktree_diff(Helpers.to_impl_args(params))
  end
end
