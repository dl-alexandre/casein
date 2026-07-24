defmodule Casein.Agents.TerminalTools.WorkspaceDigest do
  @moduledoc "workspace_digest."

  use Jido.Action,
    name: "workspace_digest",
    description:
      "Build a cold operator situation digest for the scoped workspace: agent sessions with per-pane semantic states, agent-created worktrees with landing/handoff metadata, deploy health, recent MCP activity, and detected risks. Read-only summary — never includes terminal scrollback. workspace_id is injected on pre-scoped endpoints.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters, do: Tool.object(Helpers.workspace_props())

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("workspace_digest")

  @impl Jido.Action
  def run(params, _context) do
    Impl.workspace_digest(Helpers.to_impl_args(params))
  end
end
