defmodule Casein.Agents.TerminalTools.HostHealth do
  @moduledoc "terminal_host_health."

  use Jido.Action,
    name: "terminal_host_health",
    description:
      "Read the current host watchdog health snapshot. Returns the same normalized state the Casein Host health menu row displays: Healthy / Warning / Pressure / Stuck / Stale / Unknown, freshness, load, CPU idle, memory, swap, OpenCode/BEAM counts, and bounded recent alerts. Read-only: it never mutates the host.",
    category: "terminal",
    tags: ["terminal", "host"],
    vsn: "1.0.0",
    schema: [workspace_id: [type: :string]]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.Helpers
  alias Casein.Terminals.HostHealth
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
        "Unknown or stale host health is not a healthy host. Read reason and latest_alert_at."
      ]
    }
  end

  @impl Jido.Action
  def run(_params, _context), do: {:ok, HostHealth.snapshot()}
end
