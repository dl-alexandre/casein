defmodule Casein.Agents.TerminalTools.HostCapacity do
  @moduledoc "terminal_host_capacity."

  use Jido.Action,
    name: "terminal_host_capacity",
    description:
      "Read the current host worker capacity probe. Returns load1, nproc, configured load limit, MemAvailable, and an honest healthy/constrained/unknown status. Read-only: it never launches or stops workers.",
    category: "terminal",
    tags: ["terminal", "orchestration"],
    vsn: "1.0.0",
    schema: [workspace_id: [type: :string]]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.Helpers
  alias Casein.Terminals.HostCapacity
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters, do: Tool.object(Helpers.workspace_props(), [])

  @impl Casein.Agents.ToolAction
  def mcp_metadata do
    %{
      mutation?: false,
      danger_level: :low,
      capabilities: [:terminal_read],
      recovery_hints: [
        "Use this probe before assigning a worker wave; unknown capacity is not spare capacity."
      ]
    }
  end

  @impl Jido.Action
  def run(_params, _context), do: {:ok, HostCapacity.snapshot()}
end
