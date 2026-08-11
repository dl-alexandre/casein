defmodule Casein.Agents.TerminalTools.McpSelfTest do
  @moduledoc "mcp_self_test."

  use Jido.Action,
    name: "mcp_self_test",
    description:
      "Exercise the MCP terminal verb surface against the RUNNING backend and report per-verb OK / UNDEFINED / ERROR. Names the resolved adapter module so a config-vs-prod divergence is visible. Safe on a live fleet: no destructive verbs; any writes are confined to a throwaway scratch session that is killed afterwards. Catches the class where capture_*/send_command work but paste_text/send_keys are missing on the configured backend.",
    category: "terminal",
    tags: ["terminal", "diagnostics"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.SelfTest}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters, do: Tool.object(Helpers.workspace_props())

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("mcp_self_test")

  @impl Jido.Action
  def run(params, _context) do
    SelfTest.run(Helpers.to_impl_args(params))
  end
end
