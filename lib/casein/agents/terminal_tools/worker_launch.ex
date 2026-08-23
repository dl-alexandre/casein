defmodule Casein.Agents.TerminalTools.WorkerLaunch do
  @moduledoc "worker_launch."

  use Jido.Action,
    name: "worker_launch",
    description:
      "Launch a visible Casein worker window into an isolated worktree, never a hidden subagent, and return one structured receipt joining session, pane, runtime, task, worktree, branch, and handle. Pass initial_prompt to submit the first brief with confirmation; an unconfirmed submit is a loud error that still includes the inspectable worker receipt.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.1.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      runtime: [type: :string, required: true],
      task_slug: [type: :string, required: true],
      label: [type: :string],
      initial_prompt: [type: :string],
      dry_run: [type: :boolean],
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
          initial_prompt: %{
            type: "string",
            description:
              "Optional first worker brief. It is pasted and submitted only after the visible pane and durable work handle are recorded; delivery must be confirmed."
          },
          dry_run: %{
            type: "boolean",
            description:
              "When true, print the spawn plan only — no window is opened and no pane_id is returned."
          }
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
