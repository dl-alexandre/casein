defmodule Casein.Agents.PreviewTools.ControlSession do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession.{
    Close,
    Interaction,
    Navigation,
    Observation,
    PaneOpen,
    Playback,
    Visibility
  }

  defdelegate open_unified(a1, a2), to: PaneOpen
  defdelegate open_app_preview(a1), to: PaneOpen
  defdelegate open_app_preview(a1, a2), to: PaneOpen
  defdelegate open_app_here(a1), to: PaneOpen
  defdelegate open_app_here(a1, a2), to: PaneOpen
  defdelegate open_localhost_url(a1, a2, a3), to: PaneOpen
  defdelegate split_preview_pane(a1, a2, a3), to: PaneOpen
  defdelegate preview_visibility_from_activity_for_surface(a1), to: Visibility
  defdelegate navigate_pane(a1), to: Navigation
  defdelegate observe_pane(a1, a2), to: Observation
  defdelegate observe(a1), to: Observation
  defdelegate observe_live(a1), to: Observation
  defdelegate elements(a1), to: Observation
  defdelegate report_errors(a1), to: Observation
  defdelegate click(a1), to: Interaction
  defdelegate type(a1), to: Interaction
  defdelegate press(a1), to: Interaction
  defdelegate compute_affected_element_ids(a1, a2), to: Interaction
  defdelegate enrich_observation_diff_for_test(a1), to: Interaction
  defdelegate preview_diff_opts_for_test(a1), to: Interaction
  defdelegate playback_open(a1, a2), to: Playback
  defdelegate close(a1), to: Close

end
