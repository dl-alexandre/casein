defmodule Casein.Agents.PreviewTools.ControlSession.PaneOpen do
  @moduledoc false

  alias Casein.Agents.PreviewTools.{PortProbing, SurfaceDiscovery}
  alias Casein.Agents.PreviewTools.TmuxTopology, as: PreviewTmuxTopology
  alias Casein.Agents.PreviewTools.ControlSession.Shared
  alias Casein.Agents.PreviewTools.ControlSession.SessionResolve
  alias Casein.Agents.PreviewTools.ControlSession.Visibility
  alias Casein.Agents.PreviewTools.ControlSession.Navigation
  alias Casein.PreviewControl
  alias Casein.PreviewPanes
  alias Casein.Previews.Url

  # Unified entry point for the preview_open tool. Routes by `mode` to the
  # existing per-surface handlers, which each validate their own required
  # arguments (localhost → port, here → tmux_session) and return structured
  # errors. The deprecated preview_open_app/_localhost/_here tools call those
  # same handlers directly.
  @valid_open_modes ~w(app localhost here)
  def open_unified(workspace, params) do
    case Shared.string_param(params, :mode) || "app" do
      "app" -> open_app_preview(workspace, params)
      "localhost" -> PortProbing.open_localhost_preview(workspace, params)
      "here" -> open_app_here(workspace, params)
      other -> {:error, invalid_open_mode_error(other)}
    end
  end

  defp invalid_open_mode_error(mode) do
    %{
      error: :invalid_mode,
      mode: mode,
      allowed_modes: @valid_open_modes,
      message:
        "preview_open mode must be one of #{Enum.join(@valid_open_modes, ", ")} (default app)."
    }
  end

  @doc "Open the app (or named) preview surface for agent feedback."
  @spec open_app_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_app_preview(workspace, params \\ %{}) do
    surface = Map.get(params, "surface", Map.get(params, :surface, "app"))

    with {:ok, url, preview_source} <- SurfaceDiscovery.resolve_url(workspace, surface, params),
         :ok <- SessionResolve.ensure_unambiguous_tmux_session(workspace, params),
         opts <- SessionResolve.split_opts(params, workspace),
         {:ok, result} <- open_or_split_preview_pane(workspace, url, opts),
         {:ok, result} <- Navigation.maybe_refuse_self_preview_recursion(workspace, url, result),
         duplicate_cleanup <- cleanup_duplicate_preview_panes(workspace, url, result, opts),
         {:ok, navigation} <- Navigation.maybe_navigate_to_workspace_after_open(workspace, result) do
      health = Visibility.verify_preview_ready(result.session, navigation)

      operator_visibility =
        Visibility.ensure_operator_preview_visible(workspace, result.registration, params, health)

      payload =
        Shared.session_payload(result.session, navigation)
        |> Map.put(:pane_id, result.pane_id)
        |> Map.put(:preview_source, preview_source)
        |> put_shared_registration(result.registration)
        |> Map.put(:health, health)
        |> Map.put(:visibility, operator_visibility.visibility)
        |> Map.put(
          :operator_visibility,
          Visibility.operator_visibility_payload(operator_visibility)
        )
        |> Visibility.put_user_visibility(operator_visibility)
        |> maybe_put_reused(result)
        |> maybe_put_duplicate_cleanup(duplicate_cleanup)
        |> maybe_put_operator_focus(Map.get(operator_visibility, :focus))
        |> Navigation.maybe_put_self_preview_snapshot(result)
        |> Shared.put_preview_next("preview_observe_live", %{session_id: result.session.id})

      {:ok, payload}
    end
  end

  @doc "Open the app preview beside the calling agent."
  @spec open_app_here(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_app_here(workspace, params \\ %{}) do
    with session when is_binary(session) <- Shared.string_param(params, :tmux_session) do
      surface = Map.get(params, "surface", Map.get(params, :surface, "app"))

      params =
        params
        |> Map.put("tmux_session", session)
        |> Map.put("runtime_required", true)

      with {:ok, url, preview_source} <- SurfaceDiscovery.resolve_url(workspace, surface, params),
           :ok <- SessionResolve.ensure_unambiguous_tmux_session(workspace, params),
           {:ok, placement} <- PreviewTmuxTopology.resolve_preview_placement(session, params),
           opts <-
             SessionResolve.split_opts(
               params
               |> Map.put("anchor_pane_id", placement.anchor_pane_id)
               |> Map.put("anchor_window_id", placement.anchor_window_id)
               |> Map.put("placement", placement.placement),
               workspace
             ),
           {:ok, result} <- open_or_split_preview_pane(workspace, url, opts),
           duplicate_cleanup <- cleanup_duplicate_preview_panes(workspace, url, result, opts),
           {:ok, navigation} <- Navigation.maybe_navigate_to_workspace(workspace, result.session) do
        health = Visibility.verify_preview_ready(result.session, navigation)

        operator_visibility =
          Visibility.ensure_operator_preview_visible(
            workspace,
            result.registration,
            params,
            health
          )

        payload =
          Shared.session_payload(result.session, navigation)
          |> Map.put(:pane_id, result.pane_id)
          |> Map.put(:preview_source, preview_source)
          |> put_shared_registration(result.registration)
          |> Map.put(:health, health)
          |> Map.put(:visibility, operator_visibility.visibility)
          |> Map.put(
            :operator_visibility,
            Visibility.operator_visibility_payload(operator_visibility)
          )
          |> Map.put(:placement, PreviewTmuxTopology.placement_payload(result.registration))
          |> Visibility.put_user_visibility(operator_visibility)
          |> maybe_put_reused(result)
          |> maybe_put_repaired_placement(result)
          |> maybe_put_duplicate_cleanup(duplicate_cleanup)
          |> maybe_put_operator_focus(Map.get(operator_visibility, :focus))
          |> Shared.put_preview_next("preview_observe_live", %{session_id: result.session.id})

        {:ok, payload}
      end
    else
      _ -> {:error, SessionResolve.missing_tmux_session_error()}
    end
  end

  @doc false
  def open_localhost_url(workspace, params, url) do
    with :ok <- SessionResolve.ensure_unambiguous_tmux_session(workspace, params),
         opts <- SessionResolve.split_opts(params, workspace),
         {:ok, result} <- open_or_split_preview_pane(workspace, url, opts),
         duplicate_cleanup <- cleanup_duplicate_preview_panes(workspace, url, result, opts) do
      health = Visibility.verify_preview_ready(result.session, %{})

      operator_visibility =
        Visibility.ensure_operator_preview_visible(workspace, result.registration, params, health)

      payload =
        Shared.session_payload(result.session)
        |> Map.put(:pane_id, result.pane_id)
        |> put_shared_registration(result.registration)
        |> Map.put(:health, health)
        |> Map.put(:visibility, operator_visibility.visibility)
        |> Map.put(
          :operator_visibility,
          Visibility.operator_visibility_payload(operator_visibility)
        )
        |> Visibility.put_user_visibility(operator_visibility)
        |> maybe_put_reused(result)
        |> maybe_put_duplicate_cleanup(duplicate_cleanup)
        |> maybe_put_operator_focus(Map.get(operator_visibility, :focus))
        |> Shared.put_preview_next("preview_observe_live", %{session_id: result.session.id})

      {:ok, payload}
    end
  end

  defp open_or_split_preview_pane(workspace, url, opts) do
    if Keyword.get(opts, :share_session) do
      open_shared_preview_pane(workspace, url, opts)
    else
      open_owned_or_reused_preview_pane(workspace, url, opts)
    end
  end

  defp open_shared_preview_pane(workspace, url, opts) do
    with :ok <- ensure_shared_preview_source(workspace, url, opts),
         :ok <- PortProbing.preflight_preview_url(url, opts) do
      split_preview_pane(workspace, url, Keyword.put(opts, :preflight_done, true))
    end
  end

  defp open_owned_or_reused_preview_pane(workspace, url, opts) do
    case existing_preview_pane_for_url(workspace, url, opts) do
      {:ok, result} ->
        with :ok <- PortProbing.preflight_preview_url(url, opts) do
          {:ok, Map.put(result, :reused, true)}
        end

      {:misplaced, registration, mismatch} ->
        with :ok <- PortProbing.preflight_preview_url(url, opts),
             :ok <- PreviewTmuxTopology.repair_misplaced_preview_pane(registration),
             {:ok, result} <-
               split_preview_pane(workspace, url, Keyword.put(opts, :preflight_done, true)) do
          {:ok,
           result
           |> Map.put(:repaired_placement, true)
           |> Map.put(:placement_mismatch, mismatch)}
        end

      _ ->
        with :ok <- PortProbing.preflight_preview_url(url, opts) do
          split_preview_pane(workspace, url, Keyword.put(opts, :preflight_done, true))
        end
    end
  end

  defp ensure_shared_preview_source(workspace, url, opts) do
    source =
      case Keyword.get(opts, :attach_to_pane_id) do
        pane_id when is_binary(pane_id) and pane_id != "" ->
          PreviewPanes.get_by_pane(pane_id)

        _ ->
          url
          |> Url.origin_of()
          |> then(fn
            nil ->
              nil

            origin ->
              workspace
              |> SurfaceDiscovery.active_pane_registrations_by_origin()
              |> Map.get(origin)
          end)
      end

    case source do
      %{workspace_id: workspace_id} ->
        Shared.ensure_pane_workspace_scope(workspace, workspace_id)

      _ ->
        {:error,
         %{
           error: :no_shared_preview_found,
           message: "No active preview pane is available to share for this preview origin."
         }}
    end
  end

  defp existing_preview_pane_for_url(workspace, url, opts) do
    case Url.origin_of(url) do
      nil ->
        :not_found

      origin ->
        case misplaced_preview_pane_for_origin(workspace, origin, opts) do
          {:misplaced, _registration, _mismatch} = misplaced ->
            misplaced

          :not_found ->
            pane_id =
              workspace
              |> SurfaceDiscovery.active_panes_by_origin()
              |> Map.get(origin)

            case reuse_preview_pane(pane_id, workspace, url, opts) do
              {:ok, result} ->
                {:ok, result}

              {:misplaced, registration, mismatch} ->
                {:misplaced, registration, mismatch}

              _ ->
                workspace
                |> stale_preview_pane_for_url(url, opts)
                |> reuse_stale_preview_pane(workspace, url, opts)
            end
        end
    end
  end

  defp misplaced_preview_pane_for_origin(workspace, origin, opts) do
    with tmux_session when is_binary(tmux_session) and tmux_session != "" <-
           Keyword.get(opts, :tmux_session),
         anchor_window_id when is_binary(anchor_window_id) and anchor_window_id != "" <-
           Keyword.get(opts, :anchor_window_id),
         id when is_binary(id) <- Shared.workspace_id(workspace) do
      id
      |> PreviewPanes.list_for_workspace()
      |> Enum.find_value(fn registration ->
        if registration_matches_origin?(registration, origin) and
             registration.tmux_session == tmux_session and
             Map.get(registration, :anchor_window_id) == anchor_window_id do
          current_window_id =
            Map.get(registration, :pane_window_id) ||
              PreviewTmuxTopology.pane_window_id(tmux_session, registration.pane_id)

          if current_window_id not in [nil, anchor_window_id] do
            {:misplaced, registration,
             %{
               pane_id: registration.pane_id,
               current_window_id: current_window_id,
               expected_window_id: anchor_window_id
             }}
          end
        end
      end) || :not_found
    else
      _ -> :not_found
    end
  end

  defp registration_matches_origin?(registration, origin) do
    SurfaceDiscovery.registration_origin(registration) == origin or
      Url.origin_of(Map.get(registration, :url)) == origin
  end

  defp cleanup_duplicate_preview_panes(workspace, url, result, opts) do
    current_registration =
      Map.get(result, :registration) ||
        with pane_id when is_binary(pane_id) <- Map.get(result, :pane_id) do
          PreviewPanes.get_by_pane(pane_id)
        end

    case current_registration do
      current when is_map(current) ->
        with origin when is_binary(origin) <-
               SurfaceDiscovery.registration_origin(current) || Url.origin_of(url),
             id when is_binary(id) <- Shared.workspace_id(workspace) do
          tmux_session = Keyword.get(opts, :tmux_session)

          id
          |> PreviewPanes.list_for_workspace()
          |> Enum.reject(&(&1.pane_id == current.pane_id))
          |> Enum.filter(&registration_matches_origin?(&1, origin))
          |> Enum.filter(&duplicate_cleanup_scope?(&1, tmux_session))
          |> Enum.map(&cleanup_duplicate_preview_pane/1)
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  defp duplicate_cleanup_scope?(registration, tmux_session)
       when is_binary(tmux_session) and tmux_session != "" do
    registration.tmux_session == tmux_session
  end

  defp duplicate_cleanup_scope?(_registration, _tmux_session), do: true

  defp cleanup_duplicate_preview_pane(registration) do
    kill_result = Shared.kill_preview_pane(registration.tmux_session, registration.pane_id)
    deregister_result = PreviewPanes.deregister(registration.pane_id)

    %{
      pane_id: registration.pane_id,
      tmux_session: registration.tmux_session,
      url: registration.display_url || registration.url,
      kill_result: cleanup_result(kill_result),
      deregister_result: cleanup_result(deregister_result)
    }
  end

  defp cleanup_result(:ok), do: "ok"
  defp cleanup_result({:error, reason}), do: Shared.health_error(reason)
  defp cleanup_result(other), do: Shared.health_error(other)

  defp reuse_preview_pane(nil, _workspace, _url, _opts), do: :not_found

  defp reuse_preview_pane(pane_id, workspace, url, opts) do
    with %{
           workspace_id: registration_workspace_id,
           tmux_session: tmux_session
         } = registration <-
           PreviewPanes.get_by_pane(pane_id),
         :ok <- Shared.ensure_pane_workspace_scope(workspace, registration_workspace_id),
         :ok <- PreviewTmuxTopology.ensure_pane_tmux_session_scope(pane_id, opts),
         :ok <- PreviewTmuxTopology.ensure_pane_placement_scope(pane_id, opts),
         :ok <- Shared.ensure_tmux_pane_exists(tmux_session, pane_id) do
      reuse_registered_preview_pane(registration, workspace, url, opts)
    else
      {:error, {:preview_misplaced, registration, mismatch}} ->
        {:misplaced, registration, mismatch}

      _ ->
        :not_found
    end
  end

  defp stale_preview_pane_for_url(workspace, url, opts) do
    with origin when is_binary(origin) <- Url.origin_of(url),
         tmux_session when is_binary(tmux_session) and tmux_session != "" <-
           Keyword.get(opts, :tmux_session) ||
             SessionResolve.resolve_tmux_session(workspace, opts) do
      panes = Shared.terminals().list_session_panes(tmux_session)

      find_stale_preview_pane_by_scrollback(tmux_session, panes, origin) ||
        single_preview_holder_candidate(tmux_session, panes)
    else
      _ -> nil
    end
  end

  defp find_stale_preview_pane_by_scrollback(tmux_session, panes, origin) do
    Enum.find_value(panes, fn pane ->
      pane_id = Map.get(pane, :id) || Map.get(pane, "id")

      with pane_id when is_binary(pane_id) <- pane_id,
           scrollback when is_binary(scrollback) and scrollback != "" <-
             Shared.terminals().capture_scrollback(tmux_session,
               target: pane_id,
               ansi: false,
               lines: 20
             ),
           true <- String.contains?(scrollback, "Preview pane registered"),
           pane_url when is_binary(pane_url) <- preview_registered_url(scrollback),
           ^origin <- Url.origin_of(pane_url) do
        %{pane_id: pane_id, tmux_session: tmux_session}
      else
        _ -> nil
      end
    end)
  end

  defp single_preview_holder_candidate(tmux_session, panes) do
    case Enum.filter(panes, &preview_holder_candidate?/1) do
      [pane] ->
        pane_id = Map.get(pane, :id) || Map.get(pane, "id")
        %{pane_id: pane_id, tmux_session: tmux_session}

      _ ->
        nil
    end
  end

  defp preview_holder_candidate?(pane) do
    command = Map.get(pane, :current_command) || Map.get(pane, "current_command")
    active = Map.get(pane, :active) || Map.get(pane, "active")

    (command in ["bash", "sh", "zsh"] ||
       (is_binary(command) and String.contains?(command, "casein-preview"))) and
      active in [false, "0", 0, nil]
  end

  defp preview_registered_url(scrollback) when is_binary(scrollback) do
    case Regex.run(~r/^\s*url:\s+(\S+)/m, scrollback) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp reuse_stale_preview_pane(nil, _workspace, _url, _opts), do: :not_found

  defp reuse_stale_preview_pane(
         %{pane_id: pane_id, tmux_session: tmux_session},
         workspace,
         url,
         opts
       ) do
    with :ok <- Shared.ensure_tmux_pane_exists(tmux_session, pane_id),
         {:ok, registration} <-
           PreviewPanes.register(%{
             "pane_id" => pane_id,
             "url" => url,
             "workspace" => workspace,
             "workspace_id" => Shared.workspace_id(workspace),
             "cwd" => Keyword.get(opts, :cwd) || Shared.workspace_host_path(workspace),
             "viewport" => Shared.viewport_string(Keyword.get(opts, :viewport)),
             "tmux_session" => tmux_session,
             "actor_id" => Keyword.get(opts, :actor_id),
             "default_headers" => Keyword.get(opts, :default_headers),
             "storage_profile" => Keyword.get(opts, :storage_profile),
             "storage_profile_name" => Keyword.get(opts, :storage_profile_name),
             "placement" => Keyword.get(opts, :placement),
             "anchor_pane_id" => Keyword.get(opts, :anchor_pane_id),
             "anchor_window_id" => Keyword.get(opts, :anchor_window_id),
             "pane_window_id" => PreviewTmuxTopology.pane_window_id(tmux_session, pane_id)
           }),
         session when not is_nil(session) <- open_registered_session(registration) do
      {:ok,
       %{
         pane_id: registration.pane_id,
         session: session,
         registration: registration,
         rehydrated: true
       }}
    else
      _ -> :not_found
    end
  end

  defp reuse_registered_preview_pane(registration, workspace, url, opts) do
    case open_registered_session(registration) do
      nil ->
        recover_registered_preview_pane(registration, workspace, url, opts)

      _session ->
        case PreviewPanes.navigate(registration.pane_id, url) do
          {:ok, updated_registration} ->
            {:ok,
             %{
               pane_id: updated_registration.pane_id,
               session: open_registered_session(updated_registration),
               registration: updated_registration
             }}

          {:error, _reason} ->
            recover_registered_preview_pane(registration, workspace, url, opts)
        end
    end
  end

  defp open_registered_session(%{control_session_id: session_id, preview_id: preview_id}) do
    PreviewControl.get_open_session_for_preview(session_id, preview_id)
  end

  defp recover_registered_preview_pane(registration, workspace, url, opts) do
    with {:ok, updated_registration} <-
           PreviewPanes.register(%{
             "pane_id" => registration.pane_id,
             "url" => url,
             "workspace" => workspace,
             "workspace_id" => Shared.workspace_id(workspace),
             "cwd" => Keyword.get(opts, :cwd) || Shared.workspace_host_path(workspace),
             "viewport" => Shared.viewport_string(Keyword.get(opts, :viewport)),
             "tmux_session" => registration.tmux_session || Keyword.get(opts, :tmux_session),
             "actor_id" => Keyword.get(opts, :actor_id),
             "default_headers" => Keyword.get(opts, :default_headers),
             "storage_profile" => Keyword.get(opts, :storage_profile),
             "storage_profile_name" => Keyword.get(opts, :storage_profile_name),
             "placement" => Keyword.get(opts, :placement),
             "anchor_pane_id" => Keyword.get(opts, :anchor_pane_id),
             "anchor_window_id" => Keyword.get(opts, :anchor_window_id),
             "pane_window_id" =>
               PreviewTmuxTopology.pane_window_id(
                 registration.tmux_session || Keyword.get(opts, :tmux_session),
                 registration.pane_id
               )
           }),
         session when not is_nil(session) <- open_registered_session(updated_registration) do
      {:ok,
       %{
         pane_id: updated_registration.pane_id,
         session: session,
         registration: updated_registration,
         recovered: true
       }}
    else
      _ -> :not_found
    end
  end

  defp maybe_put_reused(payload, %{reused: true}), do: Map.put(payload, :reused, true)
  defp maybe_put_reused(payload, _), do: payload

  defp put_shared_registration(payload, %{shared: true} = registration) do
    payload
    |> Map.put(:shared, true)
    |> Map.put(:source_pane_id, Map.get(registration, :source_pane_id))
  end

  defp put_shared_registration(payload, _), do: payload

  defp maybe_put_repaired_placement(payload, %{repaired_placement: true} = result) do
    payload
    |> Map.put(:repaired_placement, true)
    |> Map.put(:previous_placement, Map.get(result, :placement_mismatch))
  end

  defp maybe_put_repaired_placement(payload, _), do: payload

  defp maybe_put_duplicate_cleanup(payload, []), do: payload

  defp maybe_put_duplicate_cleanup(payload, cleaned) when is_list(cleaned) do
    Map.put(payload, :duplicate_cleanup, %{removed_panes: cleaned})
  end

  defp maybe_put_operator_focus(payload, {:ok, focus}),
    do: Map.put(payload, :operator_focus, focus)

  defp maybe_put_operator_focus(payload, {:error, reason}),
    do: Map.put(payload, :operator_focus_error, reason)

  @doc """
  Split the active tmux window and run `casein-preview` in the new pane.

  Options:
    * `:tmux_session` — required workspace tmux session name
    * `:cwd` — working directory for the split (defaults to workspace path)
    * `:viewport` — optional locked viewport (`WxH` string or map)
    * `:actor_id` — audit identity
  """
  @spec split_preview_pane(map(), String.t(), keyword()) ::
          {:ok, %{pane_id: String.t(), session: struct()}} | {:error, term()}
  def split_preview_pane(workspace, url, opts) when is_map(workspace) and is_binary(url) do
    tmux_session = SessionResolve.resolve_tmux_session(workspace, opts)

    opts =
      opts
      |> Keyword.put_new(:tmux_session, tmux_session)
      |> Keyword.put_new(:workspace_id, Shared.workspace_id(workspace))

    with true <- is_binary(tmux_session) and tmux_session != "",
         :ok <- PortProbing.maybe_preflight_preview_url(url, opts),
         {:ok, split_target_pane_id} <- split_target_pane_id(tmux_session, opts),
         command <- preview_command(url, opts),
         {:ok, pane_id} <-
           Shared.terminals().split_pane(tmux_session, split_target_pane_id, "h",
             cwd: Keyword.get(opts, :cwd) || Shared.workspace_host_path(workspace),
             command: command
           ),
         :ok <- Shared.ensure_tmux_pane_exists(tmux_session, pane_id),
         # tmux focuses the new preview holder; restore the operator pane so
         # Ghostty keeps streaming shell output instead of casein-preview text.
         :ok <- Shared.terminals().select_pane(tmux_session, split_target_pane_id),
         {:ok, registration} <- await_pane_registration(pane_id, workspace, url, opts),
         :ok <- Shared.ensure_tmux_pane_exists(tmux_session, pane_id) do
      session =
        PreviewControl.get_open_session_for_preview(
          registration.control_session_id,
          registration.preview_id
        )

      if session do
        {:ok, %{pane_id: pane_id, session: session, registration: registration}}
      else
        {:error, :session_not_found}
      end
    else
      false -> {:error, :no_tmux_session}
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_pane_registration(pane_id, workspace, url, opts) do
    Enum.reduce_while(1..40, {:error, :registration_timeout}, fn _attempt, _acc ->
      case PreviewPanes.get_by_pane(pane_id) do
        %{} = registration ->
          {:halt, {:ok, registration}}

        nil ->
          Process.sleep(50)
          {:cont, {:error, :registration_timeout}}
      end
    end)
    |> case do
      {:ok, registration} ->
        {:ok, registration}

      {:error, :registration_timeout} ->
        tmux_session =
          Keyword.get(opts, :tmux_session) || SessionResolve.workspace_tmux_session(workspace)

        with :ok <- Shared.ensure_tmux_pane_exists(tmux_session, pane_id) do
          PreviewPanes.register(%{
            "pane_id" => pane_id,
            "url" => url,
            "workspace" => workspace,
            "workspace_id" => Shared.workspace_id(workspace),
            "cwd" => Keyword.get(opts, :cwd) || Shared.workspace_host_path(workspace),
            "viewport" => Shared.viewport_string(Keyword.get(opts, :viewport)),
            "tmux_session" => tmux_session,
            "actor_id" => Keyword.get(opts, :actor_id),
            "default_headers" => Keyword.get(opts, :default_headers),
            "storage_profile" => Keyword.get(opts, :storage_profile),
            "storage_profile_name" => Keyword.get(opts, :storage_profile_name),
            "share_session" => Keyword.get(opts, :share_session),
            "attach_to_pane_id" => Keyword.get(opts, :attach_to_pane_id),
            "placement" => Keyword.get(opts, :placement),
            "anchor_pane_id" => Keyword.get(opts, :anchor_pane_id),
            "anchor_window_id" => Keyword.get(opts, :anchor_window_id),
            "pane_window_id" => PreviewTmuxTopology.pane_window_id(tmux_session, pane_id)
          })
        end
    end
  end

  defp split_target_pane_id(tmux_session, opts) do
    case Keyword.get(opts, :anchor_pane_id) do
      pane_id when is_binary(pane_id) and pane_id != "" ->
        {:ok, pane_id}

      _ ->
        active_split_target_pane_id(tmux_session)
    end
  end

  defp active_split_target_pane_id(tmux_session) do
    topology = Shared.terminals().topology_get(tmux_session, tmux: Shared.terminals().adapter())
    active_pane_id = topology.active_pane_id

    cond do
      active_pane_id?(active_pane_id) and not preview_pane?(active_pane_id) ->
        {:ok, active_pane_id}

      pane = operator_pane_candidate(topology, active_pane_id) ->
        {:ok, pane.id}

      active_pane_id?(active_pane_id) ->
        {:ok, active_pane_id}

      true ->
        {:error, :no_active_pane}
    end
  end

  defp active_pane_id?(pane_id), do: is_binary(pane_id) and pane_id != ""

  defp operator_pane_candidate(topology, active_pane_id) do
    panes = Map.get(topology, :panes, [])
    active_pane = Enum.find(panes, &(&1.id == active_pane_id))
    active_window_id = (active_pane && active_pane.window_id) || topology.active_window_id

    panes
    |> Enum.reject(&preview_pane?(&1.id))
    |> then(fn candidates ->
      Enum.find(candidates, &(&1.window_id == active_window_id)) || List.first(candidates)
    end)
  end

  defp preview_pane?(pane_id) when is_binary(pane_id) do
    case PreviewPanes.get_by_pane(pane_id) do
      nil -> false
      _ -> true
    end
  end

  defp preview_pane?(_), do: false

  defp preview_command(url, opts) do
    viewport = Shared.viewport_string(Keyword.get(opts, :viewport))

    []
    |> maybe_add_preview_env("CASEIN_API_TOKEN", Shared.preview_api_token())
    |> maybe_add_preview_env("DEVIDE_URL", Shared.preview_api_base_url())
    |> maybe_add_preview_env("DEVIDE_WORKSPACE_ID", Keyword.get(opts, :workspace_id))
    |> maybe_add_preview_env("DEVIDE_PREVIEW_PLACEMENT", Keyword.get(opts, :placement))
    |> maybe_add_preview_env("DEVIDE_PREVIEW_ANCHOR_PANE_ID", Keyword.get(opts, :anchor_pane_id))
    |> maybe_add_preview_env(
      "DEVIDE_PREVIEW_ANCHOR_WINDOW_ID",
      Keyword.get(opts, :anchor_window_id)
    )
    |> maybe_add_preview_env(
      "DEVIDE_PREVIEW_STORAGE_PROFILE",
      Keyword.get(opts, :storage_profile)
    )
    |> maybe_add_preview_env(
      "DEVIDE_PREVIEW_STORAGE_PROFILE_NAME",
      Keyword.get(opts, :storage_profile_name)
    )
    |> Kernel.++([preview_cli_executable(), Shared.shell_quote(url)])
    |> maybe_add_viewport_arg(viewport)
    |> maybe_add_share_arg(Keyword.get(opts, :share_session))
    |> maybe_add_attach_to_pane_arg(Keyword.get(opts, :attach_to_pane_id))
    |> Enum.join(" ")
  end

  defp maybe_add_preview_env(parts, _key, nil), do: parts
  defp maybe_add_preview_env(parts, _key, ""), do: parts

  defp maybe_add_preview_env(parts, key, value),
    do: parts ++ ["#{key}=#{Shared.shell_quote(value)}"]

  defp maybe_add_viewport_arg(parts, nil), do: parts
  defp maybe_add_viewport_arg(parts, ""), do: parts

  defp maybe_add_viewport_arg(parts, viewport),
    do: parts ++ ["--viewport", Shared.shell_quote(viewport)]

  defp maybe_add_share_arg(parts, true), do: parts ++ ["--share"]
  defp maybe_add_share_arg(parts, _), do: parts

  defp maybe_add_attach_to_pane_arg(parts, nil), do: parts
  defp maybe_add_attach_to_pane_arg(parts, ""), do: parts

  defp maybe_add_attach_to_pane_arg(parts, pane_id),
    do: parts ++ ["--attach-to-pane", Shared.shell_quote(pane_id)]

  defp preview_cli_executable do
    case Application.get_env(:casein, :devide_preview_script) do
      path when is_binary(path) and path != "" ->
        Shared.shell_quote(path)

      _ ->
        case :code.priv_dir(:casein) do
          dir when is_list(dir) ->
            dir
            |> List.to_string()
            |> Path.join("scripts/casein-preview")
            |> Shared.shell_quote()

          _ ->
            "casein-preview"
        end
    end
  end
end
