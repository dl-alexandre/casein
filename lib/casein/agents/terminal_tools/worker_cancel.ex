defmodule Casein.Agents.TerminalTools.WorkerCancel do
  @moduledoc "worker_cancel."

  use Jido.Action,
    name: "worker_cancel",
    description:
      "Cancel a visible Casein worker window (M4.1 #384): kills by window id (@N, never index), never a hidden-hide, and returns one structured receipt (cancelled?, visible?, pane_id, window_id). Requires workspace_id, session, and pane. Optional window_id, handle_id, dry_run. Refuses manager/operator/unlabeled panes, the caller's own window, and the last window in the session. No durable task graph / path contracts / verifiers / worker_replace.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string, required: true],
      pane: [type: :string, required: true],
      window_id: [type: :string],
      handle_id: [type: :string],
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
          pane: Helpers.pane_param(),
          caller_pane: Helpers.caller_pane_param(),
          window_id: %{
            type: "string",
            description: "Optional tmux window id to disambiguate the target pane."
          },
          handle_id: %{
            type: "string",
            description: "Optional work-handle id to record as cancelled after a live kill."
          },
          dry_run: %{
            type: "boolean",
            description:
              "When true, classify and plan only — no window is killed and cancelled? stays false."
          }
        }),
        ["workspace_id", "session", "pane"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("worker_cancel")

  @impl Jido.Action
  def run(params, _context) do
    Session.worker_cancel(Helpers.to_impl_args(params))
  end
end
