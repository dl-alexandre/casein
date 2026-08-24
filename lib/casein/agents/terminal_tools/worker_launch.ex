defmodule Casein.Agents.TerminalTools.WorkerLaunch do
  @moduledoc "worker_launch."

  use Jido.Action,
    name: "worker_launch",
    description:
      "Launch a visible Casein worker window (M4-lite #384): spawns via spawn-agent-worker.sh into an isolated worktree, never a hidden subagent, and returns one structured receipt (pane_id, window_name, worktree_path, branch, handle_id). Requires workspace_id, session, runtime (grok|codex|claude|opencode|agent), and task_slug. Optional label, dry_run, issue (same live-holder check as terminal_bind_issue), allow_duplicate. No durable task graph / path contracts / verifiers.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      runtime: [type: :string, required: true],
      task_slug: [type: :string, required: true],
      label: [type: :string],
      dry_run: [type: :boolean],
      issue: [type: :string],
      allow_duplicate: [type: :boolean],
      caller_pane: [type: :string]
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
          caller_pane: Helpers.caller_pane_param(),
          runtime: %{
            type: "string",
            enum: ["grok", "codex", "claude", "opencode", "agent"],
            description: "Agent runtime to launch in the new worker window."
          },
          task_slug: %{
            type: "string",
            description:
              "Short slug for window/branch/worktree naming (CASEIN_AGENT_TASK). Sanitized to [A-Za-z0-9_-], max 48."
          },
          label: %{
            type: "string",
            description: "Optional chrome / work-handle label (default worker: <slug>)."
          },
          dry_run: %{
            type: "boolean",
            description:
              "When true, print the spawn plan only — no window is opened and no pane_id is returned."
          },
          issue: %{
            type: "string",
            description:
              "Optional GitHub issue to bind on the new worker (678, \"#678\", or a full URL). Applies the same live-holder check as terminal_bind_issue before spawn."
          },
          allow_duplicate: Helpers.allow_duplicate_param()
        }),
        ["workspace_id", "session", "runtime", "task_slug"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("worker_launch")

  @impl Jido.Action
  def run(params, _context) do
    Session.worker_launch(Helpers.to_impl_args(params))
  end
end
