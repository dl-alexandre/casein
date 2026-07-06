defmodule DevIDE.Agents.TerminalTools.CaptureAgent do
  @moduledoc "terminal_capture_agent."

  @default_capture_lines 120

  use Jido.Action,
    name: "terminal_capture_agent",
    description:
      "Capture scrollback from the dedicated agent pane. Avoids reading the operator pane. " <>
        "Defaults to the last #{@default_capture_lines} lines when lines is omitted.",
    category: "terminal",
    tags: ["terminal"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      session: [type: :string],
      lines: [type: :integer],
      ansi: [type: :boolean]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          lines: Helpers.lines_param(),
          ansi: Helpers.ansi_param()
        })
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_capture_agent")

  @impl Jido.Action
  def run(params, _context) do
    Impl.capture_agent(Helpers.to_impl_args(params))
  end
end
