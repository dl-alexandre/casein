defmodule Casein.Agents.PreviewTools.Impl do
  @moduledoc false

  alias Casein.Agents.PreviewTools.{
    ControlSession,
    Interactions,
    PortProbing,
    SurfaceDiscovery,
    TmuxTopology,
    WorkspaceResolution
  }

  defdelegate surfaces(workspace), to: SurfaceDiscovery
  defdelegate surfaces(workspace, params), to: SurfaceDiscovery
  defdelegate registration_origin(registration), to: SurfaceDiscovery
  defdelegate list_surfaces(workspace), to: SurfaceDiscovery

  defdelegate open_unified(workspace, params), to: ControlSession
  defdelegate open_app_preview(workspace), to: ControlSession
  defdelegate open_app_preview(workspace, params), to: ControlSession
  defdelegate open_app_here(workspace), to: ControlSession
  defdelegate open_app_here(workspace, params), to: ControlSession
  defdelegate playback_open(workspace, params), to: ControlSession

  defdelegate ensure_server_here(workspace), to: PortProbing
  defdelegate ensure_server_here(workspace, params), to: PortProbing
  defdelegate open_localhost_preview(workspace), to: PortProbing
  defdelegate open_localhost_preview(workspace, params), to: PortProbing

  defdelegate split_preview_pane(workspace, url, opts), to: TmuxTopology

  defdelegate navigate(params), to: Interactions
  defdelegate navigate_pane(params), to: Interactions
  defdelegate observe_pane(workspace, params), to: Interactions
  defdelegate observe(params), to: Interactions
  defdelegate observe_live(params), to: Interactions
  defdelegate elements(params), to: Interactions
  defdelegate click(params), to: Interactions
  defdelegate type(params), to: Interactions
  defdelegate press(params), to: Interactions
  defdelegate screenshot(params), to: Interactions
  defdelegate compare_snapshots(workspace, params), to: Interactions
  defdelegate record_start(params), to: Interactions
  defdelegate record_stop(params), to: Interactions
  defdelegate close(params), to: Interactions
  defdelegate get_storage(params), to: Interactions
  defdelegate set_cookies(params), to: Interactions
  defdelegate clear_storage(params), to: Interactions
  defdelegate report_errors(params), to: Interactions
  defdelegate reload_iframe(workspace, params), to: Interactions
  defdelegate reload_page(workspace, params), to: Interactions
  defdelegate compute_affected_element_ids(observation, regions), to: Interactions
  defdelegate enrich_observation_diff_for_test(observation), to: Interactions
  defdelegate preview_diff_opts_for_test(params), to: Interactions

  defdelegate resolve_workspace(params), to: WorkspaceResolution
end
