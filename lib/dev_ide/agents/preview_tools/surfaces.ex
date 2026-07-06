defmodule DevIDE.Agents.PreviewTools.Surfaces do
  @moduledoc "preview_surfaces."

  use Jido.Action,
    name: "preview_surfaces",
    description:
      "List discoverable preview surfaces for a workspace (manager URLs, metadata localhost ports, and ports detected from tmux terminal output). Loopback surfaces are TCP-probed at listing time: server_active is false and server_status.liveness is \"dead\" when nothing accepts connections on the port (stale runtime registrations); do not open those. Public URLs report liveness \"unprobed\". Pane-backed surfaces include separate pane_registered, operator_visible, and visibility fields; do not treat a surface as visible unless operator_visible/browser_loaded is true. Call before preview_open_app to pick a surface name.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string, required: true],
      tmux_session: [type: :string],
      runtime_id: [type: :string],
      port: [type: {:or, [:integer, :string]}],
      runtime_required: [type: :boolean]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.{Params, Tool}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Tool.object(Helpers.surface_props(), [:workspace_id])

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_surfaces")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.surfaces(workspace, Helpers.to_impl_args(params))
  end
end
