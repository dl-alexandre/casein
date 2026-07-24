defmodule Casein.Agents.PreviewTools.ControlSession.Interaction do
  @moduledoc false

  alias Casein.Agents.PreviewTools.ControlSession.Shared
  alias Casein.Agents.PreviewTools.BrowserControl
  alias Casein.PreviewControl
  alias Casein.PreviewPanes

  @doc "Click in the preview session."
  @spec click(map()) :: {:ok, map()} | {:error, term()}
  def click(params) when is_map(params) do
    with {:ok, id} <-
           Shared.parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)),
         {:ok, target} <- click_target(id, params) do
      visible_or_fallback(id, "click", target, params, fn ->
        case PreviewControl.click(id, Map.merge(target, preview_diff_opts(params))) do
          {:ok, observation} ->
            {:ok, maybe_sync_pane_navigation(id, observation) |> Shared.guide_observation(id)}

          {:error, {:origin_not_allowed, observation}} when is_map(observation) ->
            {:ok,
             maybe_show_snapshot(id, observation, :untrusted_preview_url)
             |> Shared.guide_observation(id)}

          # A preview session can drop between calls (closed/expired), the local
          # runtime can be gone, or the adapter can surface a transport error —
          # PreviewControl.click/2 returns those as {:error, term}. Propagate
          # them instead of raising CaseClauseError.
          other ->
            other
        end
      end)
    end
  end

  @doc "Type into a preview input."
  @spec type(map()) :: {:ok, map()} | {:error, term()}
  def type(params) when is_map(params) do
    with {:ok, id} <-
           Shared.parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)),
         {:ok, selector} <- type_selector(id, params),
         {:ok, text} <- Shared.required_string(params, :text) do
      opts = Shared.maybe_put_nth(%{}, params) |> Map.merge(preview_diff_opts(params))

      target = Map.merge(%{selector: selector, text: text}, opts)

      visible_or_fallback(id, "type", target, params, fn ->
        with {:ok, observation} <- PreviewControl.type(id, selector, text, opts) do
          {:ok, maybe_sync_pane_navigation(id, observation) |> Shared.guide_observation(id)}
        end
      end)
    end
  end

  @doc "Press a key in the preview session."
  @spec press(map()) :: {:ok, map()} | {:error, term()}
  def press(params) when is_map(params) do
    with {:ok, id} <-
           Shared.parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      key = Map.get(params, "key") || Map.get(params, :key)

      visible_or_fallback(id, "press", %{key: key}, params, fn ->
        with {:ok, observation} <- PreviewControl.press(id, key, preview_diff_opts(params)) do
          {:ok, maybe_sync_pane_navigation(id, observation) |> Shared.guide_observation(id)}
        end
      end)
    end
  end

  defp visible_or_fallback(session_id, action, target, params, fallback_fun)
       when is_integer(session_id) and is_function(fallback_fun, 0) do
    registration = PreviewPanes.get_by_session(session_id)
    before_artifact = visible_diff_before_artifact(session_id, registration, params)

    case try_visible_preview_action(registration, action, target, params) do
      {:ok, visible} ->
        maybe_enrich_visible_pane_diff(
          session_id,
          registration,
          action,
          visible,
          params,
          before_artifact
        )

      {:error, visible_error} ->
        with {:ok, observation} <- fallback_fun.() do
          {:ok,
           observation
           |> maybe_snapshot_visible_pane(session_id, registration)
           |> enrich_observation_diff()
           |> Map.put(:visible_effect, visible_fallback_effect(registration))
           |> Map.put(:visible_error, visible_error_payload(visible_error))
           |> Map.put(:headless_warning, headless_warning(registration, params))}
        end
    end
  end

  @doc false
  def compute_affected_element_ids(observation, regions)
      when is_map(observation) and is_list(regions) do
    affected_element_ids(observation, regions)
  end

  @doc false
  def enrich_observation_diff_for_test(observation) when is_map(observation),
    do: enrich_observation_diff(observation)

  @doc false
  def preview_diff_opts_for_test(params) when is_map(params), do: preview_diff_opts(params)

  defp preview_diff_opts(params) when is_map(params) do
    case fetch_diff_param(params) do
      {:ok, false} -> %{diff: false}
      {:ok, "false"} -> %{diff: false}
      _ -> %{}
    end
  end

  # Map.fetch (not `||`) so a present `false` is distinguished from a missing key.
  defp fetch_diff_param(params) do
    case Map.fetch(params, "diff") do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(params, :diff)
    end
  end

  defp enrich_observation_diff(observation) when is_map(observation) do
    case Shared.map_get(observation, :diff) do
      %{} = diff ->
        {affected, considered, truncated} =
          affected_element_ids_meta(observation, Shared.map_get(diff, :changed_regions) || [])

        enriched =
          diff
          |> Map.put(:affected_element_ids, affected)
          |> Map.put(:elements_considered, considered)
          |> Map.put(:elements_truncated, truncated)

        Map.put(observation, :diff, enriched)

      _ ->
        observation
    end
  end

  defp affected_element_ids_meta(observation, regions) when is_list(regions) do
    summary = Shared.map_get(observation, :dom_summary) || %{}
    elements = Shared.map_get(summary, :elements) || []
    considered = length(elements)
    truncated = Shared.map_get(summary, :elements_truncated) == true

    affected =
      observation
      |> affected_element_ids(regions)
      |> Enum.map(&Map.take(&1, [:element_id, :name, :role]))

    {affected, considered, truncated}
  end

  defp affected_element_ids(observation, regions) when is_list(regions) do
    observation
    |> Shared.elements_from_observation()
    |> Enum.filter(fn el ->
      bounds = Map.get(el, :bounds)

      is_map(bounds) and Enum.any?(regions, &overlap?(bounds, &1))
    end)
  end

  defp overlap?(bounds, region) when is_map(bounds) and is_map(region) do
    bx = coord(bounds, :x)
    by = coord(bounds, :y)
    bw = coord(bounds, :width)
    bh = coord(bounds, :height)
    rx = coord(region, :x)
    ry = coord(region, :y)
    rw = coord(region, :width)
    rh = coord(region, :height)

    bx2 = bx + bw
    by2 = by + bh
    rx2 = rx + rw
    ry2 = ry + rh

    bx < rx2 and bx2 > rx and by < ry2 and by2 > ry
  end

  defp coord(map, key) do
    case Shared.map_get(map, key) do
      n when is_number(n) -> n
      _ -> 0
    end
  end

  defp try_visible_preview_action(nil, _action, _target, _params), do: {:error, :no_visible_pane}

  defp try_visible_preview_action(registration, action, target, params) do
    workspace = %{id: registration.workspace_id}

    BrowserControl.mutate_preview_pane(
      workspace,
      registration.pane_id,
      action,
      visible_target(action, target),
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      tmux_session: registration.tmux_session
    )
  end

  defp visible_target("type", target) when is_map(target) do
    target
    |> Map.take([:selector, :nth, :text])
    |> stringify_target_keys()
  end

  defp visible_target("press", target) when is_map(target) do
    target
    |> Map.take([:key])
    |> stringify_target_keys()
  end

  defp visible_target(_action, target) when is_map(target) do
    target
    |> Map.take([:selector, :nth, :x, :y, :button, :modifiers])
    |> stringify_target_keys()
  end

  defp stringify_target_keys(target) do
    Map.new(target, fn {key, value} -> {to_string(key), value} end)
  end

  defp visible_action_payload(session_id, action, visible) do
    %{
      session_id: session_id,
      pane_id: Map.get(visible, :pane_id),
      action: action,
      visible_effect: "confirmed",
      mode: "iframe",
      status: Map.get(visible, :status),
      browser_action: Map.take(visible, [:request_id, :workspace_id, :event, :metadata])
    }
  end

  defp maybe_snapshot_visible_pane(observation, session_id, nil) do
    observation
    |> Map.put(:session_id, session_id)
  end

  defp maybe_snapshot_visible_pane(observation, session_id, registration) do
    case PreviewControl.screenshot(session_id) do
      {:ok, screenshot} ->
        artifact_path =
          Map.get(screenshot, :artifact_path) || Map.get(screenshot, "artifact_path")

        case artifact_path && PreviewPanes.show_artifact(session_id, artifact_path) do
          {:ok, updated} ->
            observation
            |> Map.put(:pane_id, updated.pane_id)
            |> Map.put(:display_url, updated.display_url)
            |> Map.put(:snapshot_url, updated.display_url)
            |> Map.put(:snapshot_mode, true)
            |> Map.put(:mode, "snapshot")
            |> Map.put(
              :latest_screenshot,
              Shared.observation_payload(%{data: screenshot, artifact_path: artifact_path})
            )

          _ ->
            observation
            |> Map.put(:pane_id, registration.pane_id)
            |> Map.put(:snapshot_warning, "missing_screenshot_artifact")
        end

      {:error, reason} ->
        observation
        |> Map.put(:pane_id, registration.pane_id)
        |> Map.put(:snapshot_warning, inspect(reason))
    end
  end

  defp visible_fallback_effect(nil), do: "headless_only"
  defp visible_fallback_effect(_registration), do: "snapshot"

  defp headless_warning(nil, params) do
    if Shared.truthy_param?(params, :allow_headless) do
      nil
    else
      "No registered visible preview pane was attached to this session; action ran in the browser automation session only."
    end
  end

  defp headless_warning(_registration, _params), do: nil

  defp visible_error_payload(error) when is_map(error), do: jsonable_visible_error(error)
  defp visible_error_payload(error) when is_atom(error), do: Atom.to_string(error)
  defp visible_error_payload(error), do: inspect(error)

  defp jsonable_visible_error(error) do
    error
    |> Map.take([:status, :reason, :pane_id, :event, :metadata])
    |> Enum.map(fn {key, value} -> {key, jsonable_visible_value(value)} end)
    |> Map.new()
  end

  defp jsonable_visible_value(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable_visible_value(value), do: value

  defp maybe_sync_pane_navigation(session_id, observation) do
    current_url = Shared.observation_url(observation)

    if is_binary(current_url) and current_url != "" do
      case PreviewPanes.sync_control_navigation(session_id, current_url) do
        {:ok, %{display_url: display_url, pane_id: pane_id}} ->
          observation
          |> Map.put(:pane_id, pane_id)
          |> Map.put(:display_url, display_url)

        {:ok, :unchanged} ->
          observation

        {:error, :untrusted_preview_url} ->
          maybe_show_snapshot(session_id, observation, :untrusted_preview_url)

        {:error, reason} ->
          Map.put(observation, :pane_sync_error, inspect(reason))
      end
    else
      observation
    end
  end

  defp maybe_show_snapshot(session_id, observation, reason) do
    with {:ok, screenshot} <- PreviewControl.screenshot(session_id),
         artifact_path when is_binary(artifact_path) <-
           Map.get(screenshot, :artifact_path) || Map.get(screenshot, "artifact_path"),
         {:ok, %{display_url: display_url, pane_id: pane_id}} <-
           PreviewPanes.show_artifact(session_id, artifact_path) do
      observation
      |> Map.put(:pane_id, pane_id)
      |> Map.put(:display_url, display_url)
      |> Map.put(:snapshot_url, display_url)
      |> Map.put(:pane_sync_warning, inspect(reason))
    else
      _ -> Map.put(observation, :pane_sync_error, inspect(reason))
    end
  end

  defp maybe_enrich_visible_pane_diff(
         session_id,
         registration,
         action,
         visible,
         _params,
         before_artifact
       ) do
    payload = visible_action_payload(session_id, action, visible)
    enrich_visible_pane_diff(payload, session_id, registration, before_artifact)
  end

  defp visible_diff_before_artifact(_session_id, nil, _params), do: nil

  defp visible_diff_before_artifact(session_id, registration, params) do
    case preview_diff_opts(params) do
      %{diff: false} ->
        nil

      _ ->
        case PreviewControl.screenshot(session_id, preview_activity_opts(registration)) do
          {:ok, observation} -> Map.get(observation, :artifact_path)
          _ -> nil
        end
    end
  end

  defp enrich_visible_pane_diff(payload, _session_id, nil, _before_artifact), do: {:ok, payload}

  defp enrich_visible_pane_diff(payload, _session_id, _registration, nil), do: {:ok, payload}

  defp enrich_visible_pane_diff(payload, session_id, registration, before_path)
       when is_binary(before_path) do
    workspace = %{id: registration.workspace_id}

    with {:ok, after_shot} <-
           PreviewControl.screenshot(session_id, preview_activity_opts(registration)),
         after_path when is_binary(after_path) <- Map.get(after_shot, :artifact_path),
         {:ok, diff} <- PreviewControl.compare_snapshots(workspace, before_path, after_path) do
      {:ok,
       payload
       |> Map.put(:visible_effect, "confirmed_with_diff")
       |> Map.put(:diff, diff)
       |> Map.put(:observation, Map.take(after_shot, [:url, :title, :artifact_path]))}
    else
      _ -> {:ok, payload}
    end
  end

  defp preview_activity_opts(registration) do
    [
      pane_id: registration.pane_id,
      preview_id: registration.preview_id,
      workspace_id: registration.workspace_id
    ]
  end

  defp click_target(session_id, params) do
    cond do
      element_id = Map.get(params, "element_id") || Map.get(params, :element_id) ->
        with {:ok, selector} <- selector_for_element(session_id, element_id) do
          {:ok, Shared.maybe_put_nth(%{selector: selector}, params)}
        end

      selector = Map.get(params, "selector") || Map.get(params, :selector) ->
        {:ok, Shared.maybe_put_nth(%{selector: selector}, params)}

      x = Map.get(params, "x") || Map.get(params, :x) ->
        y = Map.get(params, "y") || Map.get(params, :y)
        {:ok, %{x: x, y: y}}

      true ->
        {:error,
         %{
           error: :missing_target,
           message: "Pass element_id from preview_elements, selector, or x/y coordinates.",
           next_tool: "preview_elements",
           next_arguments: %{session_id: session_id}
         }}
    end
  end

  defp type_selector(session_id, params) do
    cond do
      element_id = Map.get(params, "element_id") || Map.get(params, :element_id) ->
        selector_for_element(session_id, element_id)

      selector = Map.get(params, "selector") || Map.get(params, :selector) ->
        {:ok, selector}

      true ->
        {:error,
         %{
           error: :missing_target,
           message: "Pass element_id from preview_elements or selector.",
           next_tool: "preview_elements",
           next_arguments: %{session_id: session_id}
         }}
    end
  end

  defp selector_for_element(session_id, element_id) do
    with {:ok, observation} <- PreviewControl.observe_live(session_id),
         element when is_map(element) <-
           observation
           |> Shared.elements_from_observation()
           |> Enum.find(&(Map.get(&1, :element_id) == element_id)),
         selector when is_binary(selector) and selector != "" <- Map.get(element, :selector) do
      {:ok, selector}
    else
      _ ->
        {:error,
         %{
           error: :element_not_found,
           element_id: element_id,
           message:
             "Element id was not found in the current preview observation. Call preview_elements again.",
           next_tool: "preview_elements",
           next_arguments: %{session_id: session_id}
         }}
    end
  end
end
