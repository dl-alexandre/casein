defmodule Casein.Agents.TerminalTools.Capture do
  @moduledoc "terminal_capture."

  use Jido.Action,
    name: "terminal_capture",
    description:
      "Capture a pane's scrollback to read a server log or command output. By default reads the session's active pane and full history; pass `pane` (a pane id from terminal_topology, e.g. \"%3\") to read a specific non-focused pane, `lines` to tail only the last N lines, and `ansi: false` (default) for plain text (fewer tokens).",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string, required: true],
      pane: [type: :string],
      lines: [type: :integer],
      ansi: [type: :boolean],
      allow_cross_workspace: [type: :boolean]
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
          lines: Helpers.lines_param(),
          ansi: Helpers.ansi_param()
        }),
        ["session"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_capture")

  @impl Jido.Action
  def run(params, _context) do
    Session.capture(Helpers.to_impl_args(params))
  end
end
