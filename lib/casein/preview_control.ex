defmodule Casein.PreviewControl do
  @moduledoc """
  Compatibility facade for preview browser control.

  The implementation lives in `Casein.Previews.Control`; keep this root module
  while existing preview pane and agent-tool callers migrate to the previews
  context boundary.
  """

  alias Casein.PreviewControl.Registry
  alias Casein.Previews.Control

  defdelegate open_session(workspace, surface_name, opts \\ []), to: Control
  defdelegate observe(session_id), to: Control
  defdelegate observe_live(session_id), to: Control
  defdelegate get_storage(session_id), to: Control
  defdelegate clear_storage(session_id), to: Control
  defdelegate click(session_id, target), to: Control
  defdelegate type(session_id, selector, text, opts \\ %{}), to: Control
  defdelegate press(session_id, key, opts \\ %{}), to: Control
  defdelegate navigate(session_id, path_or_url, opts \\ []), to: Control
  defdelegate go_back(session_id, opts \\ []), to: Control
  defdelegate go_forward(session_id, opts \\ []), to: Control
  defdelegate reload(session_id, opts \\ []), to: Control
  defdelegate screenshot(session_id, opts \\ []), to: Control
  defdelegate compare_snapshots(workspace, artifact_a, artifact_b, opts \\ []), to: Control
  defdelegate record_start(session_id, opts \\ []), to: Control
  defdelegate record_stop(session_id), to: Control
  defdelegate close_session(session_id), to: Control
  defdelegate latest_observation(session_id), to: Control
  defdelegate latest_screenshot(session_id), to: Control
  defdelegate latest_errors(session_id), to: Control
  defdelegate latest_observation_for_preview(preview_id), to: Control
  defdelegate get_open_session_for_preview(session_id, preview_id), to: Control
  defdelegate open_localhost_session(workspace, port, opts \\ []), to: Control
  defdelegate open_for_preview(workspace, preview, opts \\ []), to: Control
  defdelegate close_sessions_for_preview(preview_id), to: Control

  # Registry lookups (slice 2) — mcp/scope and similar callers use the facade
  defdelegate put(session_id, entry), to: Registry
  defdelegate get(session_id), to: Registry
  defdelegate update(session_id, fun), to: Registry
  defdelegate delete(session_id), to: Registry
  defdelegate clear(), to: Registry
end
