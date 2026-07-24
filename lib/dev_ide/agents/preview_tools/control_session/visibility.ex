defmodule DevIDE.Agents.PreviewTools.ControlSession.Visibility do
  @moduledoc false

  alias DevIDE.Agents.PreviewTools.ControlSession.Shared
  alias DevIDE.Agents.PreviewTools.BrowserControl
  alias DevIDE.PreviewActivity
  alias DevIDE.PreviewControl

  def put_user_visibility(payload, %{status: "confirmed"}),
    do:
      payload
      |> Map.put(:user_visible, true)
      |> Map.put(:operator_visible, true)
      |> Map.put(:preview_open_state, "visible")

  def put_user_visibility(payload, %{visibility: visibility}),
    do:
      payload
      |> Map.put(:user_visible, false)
      |> Map.put(:operator_visible, false)
      |> Map.put(:preview_open_state, "not_visible")
      |> Map.put(:user_visibility_diagnostic, Map.get(visibility || %{}, :diagnostic))
      |> Map.put(:agent_next_action, preview_not_visible_next_action(visibility))

  defp preview_not_visible_next_action(%{diagnostic: %{next_action: action}})
       when is_binary(action),
       do: action

  defp preview_not_visible_next_action(_),
    do: "call preview_observe_pane and do not tell the user the preview is visible yet"

  def operator_visibility_payload(visibility) when is_map(visibility) do
    visibility
    |> Map.drop([:visibility, :focus])
    |> Enum.map(fn
      {key, {:ok, value}} -> {key, value}
      {key, {:error, reason}} -> {key, %{status: "error", reason: Shared.health_error(reason)}}
      entry -> entry
    end)
    |> Map.new()
  end

  def verify_preview_ready(_session, %{navigation_failed: failure}) when not is_nil(failure) do
    %{
      ready: false,
      reason: :navigation_failed,
      navigation_failed: Shared.navigation_failure_payload(failure)
    }
  end

  def verify_preview_ready(%{id: session_id}, _navigation) do
    case observe_preview_health(session_id) do
      %{ready: true} = health ->
        health

      %{ready: false} = first ->
        case PreviewControl.reload(session_id) do
          {:ok, _} ->
            session_id
            |> observe_preview_health()
            |> Map.put(:repaired_by_reload, true)
            |> Map.put(
              :previous_attempt,
              Map.take(first, [:reason, :console_errors, :network_errors])
            )

          {:error, reason} ->
            first
            |> Map.put(:repaired_by_reload, false)
            |> Map.put(:reload_error, Shared.health_error(reason))
        end
    end
  end

  defp observe_preview_health(session_id) do
    case PreviewControl.observe_live(session_id) do
      {:ok, observation} ->
        errors = Shared.errors_payload(observation)
        console_errors = Map.get(errors, :console_errors, [])
        network_errors = Map.get(errors, :network_errors, [])

        %{
          ready: console_errors == [] and network_errors == [],
          reason: health_reason(console_errors, network_errors),
          url: Shared.observation_url(observation),
          title: observation |> Shared.dom_summary_title(),
          console_errors: console_errors,
          network_errors: network_errors
        }

      {:error, reason} ->
        %{
          ready: false,
          reason: :browser_observation_failed,
          observe_error: Shared.health_error(reason)
        }
    end
  end

  defp health_reason([], []), do: :ok
  defp health_reason(_console_errors, _network_errors), do: :browser_errors

  def ensure_operator_preview_visible(workspace, registration, params, %{ready: true}) do
    workspace_ids = preview_activity_workspace_ids(workspace, registration)
    Enum.each(workspace_ids, &PreviewActivity.subscribe/1)
    visible_since = DateTime.utc_now()

    focus =
      case BrowserControl.focus_preview_pane(
             workspace,
             Map.get(registration, :tmux_session),
             registration.pane_id,
             actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
             reason: "preview_open_ready"
           ) do
        {:ok, focus} -> {:ok, focus}
        {:error, reason} -> {:error, Shared.health_error(reason)}
      end

    first_wait_ms = operator_visibility_timeout(:initial, 1_000)
    reload_wait_ms = operator_visibility_timeout(:iframe_reload, 1_500)
    page_wait_ms = operator_visibility_timeout(:page_reload, 3_000)

    if first_wait_ms <= 0 and reload_wait_ms <= 0 and page_wait_ms <= 0 do
      %{
        status: "not_confirmed",
        repair_attempted: false,
        focus: focus,
        visibility: preview_visibility(registration, workspace_ids)
      }
    else
      ensure_operator_preview_visible_after_focus(
        workspace,
        registration,
        params,
        focus,
        workspace_ids,
        visible_since,
        first_wait_ms,
        reload_wait_ms,
        page_wait_ms
      )
    end
  end

  def ensure_operator_preview_visible(_workspace, registration, _params, health) do
    %{
      status: "withheld",
      reason: "preview_health_check_failed",
      health: Map.take(health || %{}, [:ready, :reason, :console_errors, :network_errors]),
      focus: {:ok, %{status: "withheld", reason: "preview_health_check_failed"}},
      visibility: preview_visibility(registration)
    }
  end

  defp ensure_operator_preview_visible_after_focus(
         workspace,
         registration,
         params,
         focus,
         workspace_ids,
         visible_since,
         first_wait_ms,
         reload_wait_ms,
         page_wait_ms
       ) do
    with :timeout <-
           await_browser_iframe_loaded(registration, workspace_ids, visible_since, first_wait_ms),
         {:ok, iframe_reload} <-
           BrowserControl.reload_preview_iframe(
             workspace,
             actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
             pane_id: registration.pane_id,
             reason: "preview_open_visibility_not_confirmed"
           ),
         :timeout <-
           await_browser_iframe_loaded(registration, workspace_ids, visible_since, reload_wait_ms),
         {:ok, page_reload} <-
           BrowserControl.reload_page(
             workspace,
             actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
             reason: "preview_open_iframe_reload_not_confirmed"
           ),
         :timeout <-
           await_browser_iframe_loaded(registration, workspace_ids, visible_since, page_wait_ms) do
      %{
        status: "not_confirmed",
        repair_attempted: true,
        repair_actions: ["iframe_reload", "page_reload"],
        focus: focus,
        iframe_reload: {:ok, iframe_reload},
        page_reload: {:ok, page_reload},
        visibility: preview_visibility(registration, workspace_ids)
      }
    else
      {:ok, entry} ->
        %{
          status: "confirmed",
          confirmed_by: "iframe_loaded",
          confirmed_at: Shared.datetime_iso(entry.inserted_at),
          focus: focus,
          visibility: preview_visibility(registration, workspace_ids)
        }

      {:error, reason} ->
        %{
          status: "repair_failed",
          error: Shared.health_error(reason),
          focus: focus,
          visibility: preview_visibility(registration, workspace_ids)
        }
    end
  end

  defp preview_visibility(registration, workspace_ids \\ nil) do
    (workspace_ids || preview_activity_workspace_ids(nil, registration))
    |> Enum.flat_map(&PreviewActivity.recent_pane(&1, registration.pane_id, 20))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> Enum.take(20)
    |> preview_visibility_from_activity()
  end

  def preview_visibility_from_activity(activity) when is_list(activity) do
    loaded_event =
      Enum.find(activity, fn entry ->
        entry.source == :browser and entry.event == "iframe_loaded"
      end)

    fresh_visible_event =
      Enum.find(activity, fn entry ->
        entry.source == :browser and entry.event in ["iframe_loaded", "visibility_heartbeat"] and
          fresh_browser_visibility_event?(entry) and loaded_browser_visibility_event?(entry)
      end)

    last_browser_event = Enum.find(activity, &(&1.source == :browser))
    state = preview_visibility_state(fresh_visible_event, loaded_event, activity)
    browser_loaded_at = loaded_event || fresh_visible_event

    %{
      browser_loaded: not is_nil(fresh_visible_event),
      browser_loaded_at: browser_loaded_at && Shared.datetime_iso(browser_loaded_at.inserted_at),
      operator_visible_state: state,
      diagnostic: preview_visibility_diagnostic(state, last_browser_event),
      last_browser_event: Shared.activity_payload(last_browser_event)
    }
  end

  def preview_visibility_from_activity(_), do: preview_visibility_from_activity([])

  @doc false
  def preview_visibility_from_activity_for_surface(activity),
    do: preview_visibility_from_activity(activity)

  defp preview_visibility_state(%{} = _fresh_visible_event, _loaded_event, _activity),
    do: "browser_loaded"

  defp preview_visibility_state(nil, %{} = loaded_event, _activity) do
    if fresh_browser_visibility_event?(loaded_event), do: "browser_loaded", else: "stale"
  end

  defp preview_visibility_state(nil, nil, activity) do
    cond do
      Enum.any?(activity, &(&1.source == :browser and &1.event == "overlay_destroyed")) ->
        "not_rendered"

      Enum.any?(activity, &(&1.source == :browser and &1.event == "iframe_error")) ->
        "iframe_error"

      Enum.any?(activity, &(&1.source == :browser and &1.event == "iframe_load_timeout")) ->
        "load_timeout"

      Enum.any?(activity, &(&1.source == :browser and &1.event == "iframe_src_assigned")) ->
        "src_assigned_no_load"

      Enum.any?(activity, &(&1.source == :browser and &1.event == "overlay_mounted")) ->
        "rendered_no_src"

      true ->
        "not_rendered"
    end
  end

  defp preview_visibility_diagnostic("browser_loaded", _event),
    do: %{reason: "iframe_loaded", next_action: "none"}

  defp preview_visibility_diagnostic("stale", event),
    do: %{
      reason: "browser_visibility_stale",
      next_action: "reload_or_reopen_preview_and_wait_for_visibility_heartbeat",
      last_browser_event: Shared.activity_payload(event)
    }

  defp preview_visibility_diagnostic("iframe_error", event),
    do: %{
      reason: "iframe_error",
      next_action: "inspect_preview_proxy_or_network_errors",
      last_browser_event: Shared.activity_payload(event)
    }

  defp preview_visibility_diagnostic("load_timeout", event),
    do: %{
      reason: "iframe_load_timeout",
      next_action: "reload_preview_iframe_or_reopen_preview_pane",
      last_browser_event: Shared.activity_payload(event)
    }

  defp preview_visibility_diagnostic("src_assigned_no_load", event),
    do: %{
      reason: "iframe_src_assigned_but_not_loaded",
      next_action: "check_preview_proxy_auth_csp_or_upstream_response",
      last_browser_event: Shared.activity_payload(event)
    }

  defp preview_visibility_diagnostic("rendered_no_src", event),
    do: %{
      reason: "overlay_mounted_without_iframe_src_confirmation",
      next_action: "reload_preview_iframe_or_check_hook_dataset",
      last_browser_event: Shared.activity_payload(event)
    }

  defp preview_visibility_diagnostic(_state, _event),
    do: %{reason: "no_browser_preview_event", next_action: "verify_visible_workspace_and_pane"}

  def fresh_browser_visibility_event?(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond) <=
      preview_visibility_fresh_ms()
  end

  def fresh_browser_visibility_event?(_), do: false

  def loaded_browser_visibility_event?(%{event: "iframe_loaded"}), do: true

  def loaded_browser_visibility_event?(%{event: "visibility_heartbeat", metadata: metadata})
      when is_map(metadata) do
    Map.get(metadata, "loaded") == true
  end

  def loaded_browser_visibility_event?(_), do: false

  defp preview_visibility_fresh_ms do
    Application.get_env(:dev_ide, :preview_operator_visibility_fresh_ms, 15_000)
  end

  defp await_browser_iframe_loaded(_registration, _workspace_ids, _since, timeout_ms)
       when timeout_ms <= 0 do
    :timeout
  end

  defp await_browser_iframe_loaded(registration, workspace_ids, since, timeout_ms) do
    case recent_browser_iframe_loaded(registration, workspace_ids, since) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        receive do
          {:preview_activity, entry} ->
            if browser_iframe_loaded_entry?(entry, registration, workspace_ids, since) do
              {:ok, entry}
            else
              await_browser_iframe_loaded(registration, workspace_ids, since, timeout_ms)
            end
        after
          timeout_ms -> :timeout
        end
    end
  end

  defp recent_browser_iframe_loaded(registration, workspace_ids, since) do
    workspace_ids
    |> Enum.flat_map(&PreviewActivity.recent_pane(&1, registration.pane_id, 20))
    |> Enum.find(&browser_iframe_loaded_entry?(&1, registration, workspace_ids, since))
    |> case do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  defp browser_iframe_loaded_entry?(entry, registration, workspace_ids, since) do
    entry.source == :browser and entry.event == "iframe_loaded" and
      entry.pane_id == registration.pane_id and entry.workspace_id in workspace_ids and
      not DateTime.before?(entry.inserted_at, since)
  end

  defp preview_activity_workspace_ids(workspace, registration) do
    [Shared.workspace_id(workspace), Map.get(registration, :workspace_id)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.flat_map(fn id -> Shared.workspaces().viewer_ids(id) end)
    |> Enum.uniq()
  end

  defp operator_visibility_timeout(stage, default) do
    app_key =
      case stage do
        :initial -> :preview_operator_visibility_initial_timeout_ms
        :iframe_reload -> :preview_operator_visibility_iframe_reload_timeout_ms
        :page_reload -> :preview_operator_visibility_page_reload_timeout_ms
      end

    Application.get_env(:dev_ide, app_key, default)
  end
end
