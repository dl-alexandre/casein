defmodule Casein.Agents.PreviewTools.OpenCurrentWorkspace do
  @moduledoc "preview_open_current_workspace."

  use Jido.Action,
    name: "preview_open_current_workspace",
    description: "Deprecated alias — prefer preview_open (mode app) on a pre-scoped endpoint.",
    category: "preview",
    tags: ["preview"],
    vsn: "1.0.0",
    schema: [
      workspace_id: [type: :string],
      workspace_path: [type: :string],
      tmux_session: [type: :string],
      surface: [type: :string],
      actor_id: [type: :string],
      assignment_id: [type: :string],
      port: [type: {:or, [:integer, :string]}],
      path: [type: :string],
      mode: [type: :string],
      anchor_pane_id: [type: :string],
      anchor_window_id: [type: :string],
      placement: [type: :string],
      viewport: [type: :string],
      new_control_session: [type: :boolean],
      force_new_pane: [type: :boolean],
      share_session: [type: :boolean],
      attach_to_pane_id: [type: :string],
      isolation_key: [type: :string],
      storage_profile: [type: :string],
      storage_profile_name: [type: :string],
      runtime_id: [type: :string],
      runtime_required: [type: :boolean],
      cwd: [type: :string],
      default_headers: [type: {:map, :string, :string}],
      loop: [type: :boolean]
    ]

  @behaviour Casein.Agents.ToolAction

  alias Casein.Agents.PreviewTools.{Helpers, Impl}
  alias McpCtl.Tool

  @impl Casein.Agents.ToolAction
  def parameters,
    do: Tool.object(Map.drop(Helpers.open_props(), [:workspace_id, :workspace_path]))

  @impl Casein.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_open_current_workspace")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.open_app_preview(workspace, Helpers.to_impl_args(params))
  end
end
