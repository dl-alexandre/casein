defmodule DevIDE.Agents.TerminalTools.OpenFileInPane do
  @moduledoc "file_open_in_pane."

  use Jido.Action,
    name: "file_open_in_pane",
    description:
      "Open a workspace file in a DevIDE file pane (or a preview pane for browser-viewable " <>
        "types: html/svg/pdf/images). Pass a workspace-relative `path`; optional `session` " <>
        "targets a tmux session and optional `line` reveals a 1-based line after open. " <>
        "Reuses the window's existing file pane when one is already open. Paths are " <>
        "re-validated server-side (never trust a raw path). Errors include binary, " <>
        "too_large, outside_root, and no_live_session.",
    category: "terminal",
    tags: ["terminal", "files"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      path: [type: :string, required: true],
      session: [type: :string],
      line: [type: :integer]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.TerminalTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl DevIDE.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          path: Helpers.file_path_param(),
          session: Helpers.session_param(),
          line: Helpers.line_param()
        }),
        ["workspace_id", "path"]
      )

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("file_open_in_pane")

  @impl Jido.Action
  def run(params, _context) do
    Impl.open_file_in_pane(Helpers.to_impl_args(params))
  end
end
