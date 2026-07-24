defmodule Casein.Agents.PreviewTools.ControlSession.Observation do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession.Shared
  alias Casein.Agents.PreviewTools.ControlSession.Visibility
  alias Casein.Agents.PreviewTools.TmuxTopology, as: PreviewTmuxTopology
  alias Casein.PreviewActivity
  alias Casein.PreviewControl
  alias Casein.PreviewPanes

  @doc "Observe a registered preview pane and its recent interaction feed."
  @spec observe_pane(map(), map()) :: {:ok, map()} | {:error, term()}
  def observe_pane(workspace, params) when is_map(workspace) and is_map(params) do
    with pane_id when is_binary(pane_id) <-
           Map.get(params, "pane_id") || Map.get(params, :pane_id) ||
             {:error, {:missing_argument, "pane_id"}},
         %{workspace_id: registration_workspace_id} = registration <-
           PreviewPanes.get_by_pane(pane_id),
         :ok <- Shared.ensure_pane_workspace_scope(workspace, registration_workspace_id) do
      limit = Shared.activity_limit(Map.get(params, "limit") || Map.get(params, :limit))
      session_id = registration.control_session_id
      latest_observation = PreviewControl.latest_observation(session_id)
      latest_screenshot = PreviewControl.latest_screenshot(session_id)

      _ =
        PreviewActivity.record(%{
          workspace_id: registration.workspace_id,
          pane_id: pane_id,
          session_id: session_id,
          preview_id: registration.preview_id,
          source: :mcp,
          event: "observed",
          summary: "preview pane observed",
          metadata: %{}
        })

      latest_activity = PreviewActivity.latest_pane(registration.workspace_id, pane_id)
      recent_activity = PreviewActivity.recent_pane(registration.workspace_id, pane_id, limit)
      visibility = Visibility.preview_visibility_from_activity(recent_activity)

      {:ok,
       %{
         pane_id: pane_id,
         workspace_id: registration.workspace_id,
         preview_id: registration.preview_id,
         session_id: session_id,
         url: registration.url,
         display_url: registration.display_url,
         source_url: Shared.pane_source_url(registration, latest_observation),
         title: Shared.preview_title(registration, latest_observation),
         mode: Shared.preview_mode(registration),
         status: Shared.preview_status(registration),
         tmux: tmux_presence(registration),
         placement: PreviewTmuxTopology.placement_payload(registration),
         snapshot_mode: Shared.preview_mode(registration) == "snapshot",
         visibility: visibility,
         browser_loaded: visibility.browser_loaded,
         browser_loaded_at: visibility.browser_loaded_at,
         operator_visible_state: visibility.operator_visible_state,
         latest_screenshot: Shared.observation_payload(latest_screenshot),
         latest_observation: Shared.observation_payload(latest_observation),
         last_interaction: Shared.activity_payload(latest_activity),
         recent_activity: Enum.map(recent_activity, &Shared.activity_payload/1)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Observe the current preview page."
  @spec observe(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe(%{"session_id" => id}),
    do:
      with(
        {:ok, id} <- Shared.parse_id(id),
        {:ok, obs} <- PreviewControl.observe(id),
        do: {:ok, Shared.guide_observation(obs, id)}
      )

  def observe(%{session_id: id}),
    do:
      with(
        {:ok, id} <- Shared.parse_id(id),
        {:ok, obs} <- PreviewControl.observe(id),
        do: {:ok, Shared.guide_observation(obs, id)}
      )

  def observe(id) when is_integer(id) do
    with {:ok, obs} <- PreviewControl.observe(id), do: {:ok, Shared.guide_observation(obs, id)}
  end

  @doc "Observe the current preview page through the browser runtime."
  @spec observe_live(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe_live(%{"session_id" => id}),
    do:
      with(
        {:ok, id} <- Shared.parse_id(id),
        {:ok, obs} <- PreviewControl.observe_live(id),
        do: {:ok, Shared.guide_observation(obs, id)}
      )

  def observe_live(%{session_id: id}),
    do:
      with(
        {:ok, id} <- Shared.parse_id(id),
        {:ok, obs} <- PreviewControl.observe_live(id),
        do: {:ok, Shared.guide_observation(obs, id)}
      )

  def observe_live(id) when is_integer(id) do
    with {:ok, obs} <- PreviewControl.observe_live(id), do: {:ok, Shared.guide_observation(obs, id)}
  end

  @doc "List visible elements with stable element_id targets for the current page."
  @spec elements(map()) :: {:ok, map()} | {:error, term()}
  def elements(params) when is_map(params) do
    with {:ok, id} <- Shared.parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)),
         {:ok, observation} <- PreviewControl.observe_live(id) do
      elements =
        observation
        |> Shared.elements_from_observation()
        |> Shared.filter_elements(Map.get(params, "query") || Map.get(params, :query))

      payload = %{session_id: id, elements: elements, count: length(elements)}

      {:ok, Shared.put_preview_next(payload, "preview_click", Shared.first_element_args(id, elements))}
    end
  end

  @doc "Report browser console/network errors from the latest observation."
  @spec report_errors(map() | integer()) :: {:ok, map()} | {:error, term()}
  def report_errors(%{"session_id" => id}),
    do: with({:ok, id} <- Shared.parse_id(id), do: do_report_errors(id))

  def report_errors(%{session_id: id}),
    do: with({:ok, id} <- Shared.parse_id(id), do: do_report_errors(id))

  def report_errors(id) when is_integer(id), do: do_report_errors(id)

  defp do_report_errors(session_id) do
    case PreviewControl.latest_errors(session_id) do
      %{console_errors: [], network_errors: []} ->
        report_errors_from_observation(session_id)

      errors ->
        {:ok, errors}
    end
  end

  defp report_errors_from_observation(session_id) do
    case PreviewControl.latest_observation(session_id) do
      nil ->
        with {:ok, observation} <- PreviewControl.observe(session_id) do
          {:ok, Shared.errors_payload(observation)}
        end

      obs ->
        {:ok, Shared.errors_payload(obs.data)}
    end
  end

  defp tmux_presence(%{tmux_session: tmux_session, pane_id: pane_id})
       when is_binary(tmux_session) and tmux_session != "" and is_binary(pane_id) do
    %{
      session: tmux_session,
      pane_id: pane_id,
      present: Shared.tmux_pane_exists?(tmux_session, pane_id)
    }
  end

  defp tmux_presence(%{pane_id: pane_id}) do
    %{pane_id: pane_id, present: nil}
  end

end
