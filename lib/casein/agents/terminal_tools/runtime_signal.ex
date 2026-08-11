defmodule Casein.Agents.TerminalTools.RuntimeSignal do
  @moduledoc "runtime_signal."

  use Jido.Action,
    name: "runtime_signal",
    description:
      "Read-only deployed runtime signal (S11/#867): deployed git revision vs origin/master (behind/ahead when countable) PLUS resolved runtime-selected modules (:tmux_adapter first, including MCP path vs legacy ops default). Surfaces when Application env/defaults disagree with what agents actually call, and whether critical MCP callbacks (paste_text/3, …) are exported. No mutations. Optional workspace_id for audit scope only.",
    category: "terminal",
    tags: ["terminal", "deployment"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Session}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do: Tool.object(Helpers.workspace_props(), [])

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("runtime_signal")

  @impl Jido.Action
  def run(params, _context) do
    Session.runtime_signal(Helpers.to_impl_args(params))
  end
end
