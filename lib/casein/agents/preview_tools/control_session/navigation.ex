defmodule Casein.Agents.PreviewTools.ControlSession.Navigation do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession.Shared
  alias Casein.PreviewControl
  alias Casein.PreviewPanes

  @doc "Navigate an embedded preview pane and broadcast the updated iframe URL."
  @spec navigate_pane(map()) :: {:ok, map()} | {:error, term()}
  def navigate_pane(params) when is_map(params) do
    with pane_id when is_binary(pane_id) <-
           Map.get(params, "pane_id") || Map.get(params, :pane_id) ||
             {:error, {:missing_argument, "pane_id"}},
         path when is_binary(path) <-
           Map.get(params, "path") || Map.get(params, :path) ||
             {:error, {:missing_argument, "path"}},
         {:ok, registration} <- PreviewPanes.navigate(pane_id, path) do
      {:ok,
       %{
         pane_id: registration.pane_id,
         session_id: registration.control_session_id,
         preview_id: registration.preview_id,
         workspace_id: registration.workspace_id,
         current_url: registration.url,
         display_url: registration.display_url,
         source_url: Map.get(registration, :source_url),
         mode: Shared.preview_mode(registration),
         status: Shared.preview_status(registration),
         snapshot_mode: Shared.preview_mode(registration) == "snapshot"
       }}
    end
  end

  def maybe_navigate_to_workspace_after_open(_workspace, %{self_preview_snapshot: true}) do
    {:ok, %{navigated_to: nil, navigation_failed: nil}}
  end

  def maybe_navigate_to_workspace_after_open(workspace, %{session: session}) do
    maybe_navigate_to_workspace(workspace, session)
  end

  def maybe_navigate_to_workspace_after_open(_workspace, _result),
    do: {:ok, %{navigated_to: nil, navigation_failed: nil}}

  def maybe_refuse_self_preview_recursion(workspace, url, result) do
    if self_preview_recursion_target?(workspace, url) do
      refuse_self_preview_snapshot(result)
    else
      {:ok, result}
    end
  end

  defp self_preview_recursion_target?(_workspace, url) when is_binary(url),
    do: Shared.devide_loopback_url?(url)

  defp self_preview_recursion_target?(_workspace, _url), do: false

  defp refuse_self_preview_snapshot(%{session: session} = result) do
    with {:ok, observation} <- PreviewControl.screenshot(session.id),
         artifact_path when is_binary(artifact_path) <- Map.get(observation, :artifact_path),
         {:ok, registration} <- PreviewPanes.show_artifact(session.id, artifact_path) do
      {:ok,
       result
       |> Map.put(:registration, registration)
       |> Map.put(:self_preview_snapshot, true)
       |> Map.put(:snapshot_mode, true)}
    else
      _ -> {:ok, result}
    end
  end

  defp refuse_self_preview_snapshot(result), do: {:ok, result}

  def maybe_put_self_preview_snapshot(payload, %{self_preview_snapshot: true}) do
    payload
    |> Map.put(:self_preview_snapshot, true)
    |> Map.put(:snapshot_mode, true)
    |> Map.put(:mode, "snapshot")
  end

  def maybe_put_self_preview_snapshot(payload, _result), do: payload

  def maybe_navigate_to_workspace(workspace, session) do
    if Shared.loopback_devide_session?(session) do
      route = Shared.workspace_viewer_route(workspace)

      case PreviewControl.navigate(session.id, route) do
        {:ok, observation} ->
          {:ok,
           %{
             navigated_to: Map.get(observation, :url) || Map.get(observation, "url") || route,
             navigation_failed: nil
           }}

        {:error, reason} ->
          {:ok, %{navigated_to: nil, navigation_failed: reason}}
      end
    else
      {:ok, %{navigated_to: nil, navigation_failed: nil}}
    end
  end
end
