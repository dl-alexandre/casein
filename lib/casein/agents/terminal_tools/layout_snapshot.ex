defmodule Casein.Agents.TerminalTools.LayoutSnapshot do
  @moduledoc "terminal_layout_snapshot — save the session's current layout as a template."

  use Jido.Action,
    name: "terminal_layout_snapshot",
    description:
      "Export the workspace tmux session's current layout as a saved template and return " <>
        "its template_id. This is the undo point for terminal_layout_apply: taking a " <>
        "layout back is just applying the snapshot. Reads the live topology and writes a " <>
        "template row — it does not touch tmux, move focus, or change any pane. " <>
        "Pass dry_run true to preview the export without saving it.",
    category: "terminal",
    tags: ["terminal", "layout", "templates"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      name: [type: :string],
      description: [type: :string],
      tags: [type: {:list, :string}],
      dry_run: [type: :boolean],
      actor_id: [type: :string],
      caller_pane: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.Helpers
  alias Casein.Agents.TerminalTools.Impl.Layout
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters do
    Tool.object(
      Map.merge(Helpers.workspace_props(), %{
        session: Helpers.session_param(),
        caller_pane: Helpers.caller_pane_param(),
        actor_id: Helpers.actor_id_param(),
        name: %{
          type: "string",
          description: "Name for the saved template. Defaults to a generated export name."
        },
        description: %{
          type: "string",
          description: "Why this snapshot exists — shown to the operator in the template library."
        },
        tags: %{
          type: "array",
          items: %{type: "string"},
          description: "Optional tags for filtering the saved template."
        },
        dry_run: %{
          type: "boolean",
          description: "When true, return the export without saving it. Defaults to false."
        }
      }),
      ["workspace_id"]
    )
  end

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_layout_snapshot")

  @impl Jido.Action
  def run(params, _context) do
    Layout.snapshot_layout(Helpers.to_impl_args(params))
  end
end
