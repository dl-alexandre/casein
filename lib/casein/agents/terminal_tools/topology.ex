defmodule Casein.Agents.TerminalTools.Topology do
  @moduledoc "terminal_topology."

  use Jido.Action,
    name: "terminal_topology",
    description:
      "Inspect a session's structure: its windows and panes with geometry, the running command per pane, and which window/pane is active. Use this to find the agent pane id after applying the agent_pair template. Every pane carries worktree_path, and worktree_shared_with when other panes sit in the same git worktree (a shared_worktrees warning is added at the top level). Pass include_liveness to also observe each agent worktree from outside — last_write_at, quiet_for_seconds and commit_count — which is the only signal that distinguishes a wedged agent from an idle one, since a wedged agent reports nothing and leaves a frozen spinner on screen. A pane whose liveness state is 'unknown' could not be observed; that is not evidence of inactivity.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string, required: true],
      caller_pane: [type: :string],
      include_liveness: [type: :boolean]
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
          include_liveness: Helpers.include_liveness_param()
        }),
        ["session"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_topology")

  @impl Jido.Action
  def run(params, _context) do
    Session.topology(Helpers.to_impl_args(params))
  end
end
