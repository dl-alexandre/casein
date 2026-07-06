defmodule DevIDE.Agents.PreviewTools.PlaybackOpen do
  @moduledoc "preview_playback_open."

  use Jido.Action,
    name: "preview_playback_open",
    description: "Open a saved recording artifact as looping playback in a fresh preview pane.",
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
      default_headers: [type: :map],
      loop: [type: :boolean],
      workspace_id: [type: :string, required: true],
      artifact_path: [type: :string, required: true]
    ]

  @behaviour DevIDE.Agents.ToolAction

  alias DevIDE.Agents.PreviewTools.{Helpers, Impl}

  @impl DevIDE.Agents.ToolAction
  def parameters, do: Helpers.playback_props()

  @impl DevIDE.Agents.ToolAction
  def mcp_metadata, do: Helpers.metadata("preview_playback_open")

  @impl Jido.Action
  def run(params, context) do
    workspace = Map.get(context, :workspace, %{})
    Impl.playback_open(workspace, Helpers.to_impl_args(params))
  end
end
