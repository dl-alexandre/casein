defmodule Casein.Agents.TerminalTools.WorkHandleCreate do
  @moduledoc "terminal_work_handle_create."

  use Jido.Action,
    name: "terminal_work_handle_create",
    description:
      "Create a durable work handle that survives pane respawn. Optionally attach it to a session/pane and set a recorded status/label. Returns handle_id; use terminal_work_handle_get to resolve the current pane and recorded status. Pass handle_id to reattach an existing handle after respawn.",
    category: "terminal",
    tags: ["terminal", "work_handle"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      session: [type: :string],
      pane: [type: :string],
      label: [type: :string],
      status: [type: :string],
      message: [type: :string],
      handle_id: [type: :string]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.TerminalTools.{Helpers, Impl.Agent}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do:
      Tool.object(
        Map.merge(Helpers.workspace_props(), %{
          session: Helpers.session_param(),
          pane: Helpers.pane_param(),
          label: %{
            type: "string",
            description: "Human-readable label for the work (not derived from pane title)."
          },
          status: %{
            type: "string",
            description:
              "Recorded status stored on the handle (e.g. working, blocked). Never scraped from the screen."
          },
          message: %{
            type: "string",
            description: "Optional short status detail (truncated)."
          },
          handle_id: %{
            type: "string",
            description:
              "Existing handle to reattach after pane respawn. When set, session and pane are required and no new id is minted."
          }
        }),
        ["workspace_id"]
      )

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("terminal_work_handle_create")

  @impl Jido.Action
  def run(params, _context) do
    Agent.work_handle_create(Helpers.to_impl_args(params))
  end
end
