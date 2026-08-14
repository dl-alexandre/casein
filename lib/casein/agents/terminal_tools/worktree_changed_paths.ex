defmodule Casein.Agents.TerminalTools.WorktreeChangedPaths do
  @moduledoc "worktree_changed_paths."

  use Jido.Action,
    name: "worktree_changed_paths",
    description:
      "Read-only structured dirty-path list for one worker pane (M4.3 #384): joins WorkerStatus identity with git status --porcelain=v1 -z (same porcelain AgentProgress fingerprints). Returns status_state, changed_paths[{xy, path, orig_path?}], count, truncated?. status_state unknown never emits changed_paths: [] — operators treat an empty list as proof the tree is clean. No diff, no path-contract language, no scrollback, no mutations. worktree_diff / worker_replace / durable graphs remain out of scope. Requires workspace_id, session, and pane.",
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
  def mcp_metadata, do: Helpers.metadata("worktree_changed_paths")

  @impl Jido.Action
  def run(params, _context) do
    Session.worktree_changed_paths(Helpers.to_impl_args(params))
  end
end
