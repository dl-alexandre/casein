defmodule DevIDE.Agents.PreviewTools do
  @moduledoc """
  Narrow agent-facing preview operations.

  Agents can open workspace surfaces, observe pages, interact with trusted
  previews, and capture evidence — without arbitrary browser or external URL
  access.
  """

  alias DevIDE.PreviewActivity
  alias DevIDE.Agents.{AgentPane, BrowserControl}
  alias DevIDE.PreviewControl
  alias DevIDE.PreviewPanes
  alias DevIDE.Previews
  alias DevIDE.Previews.{Surface, SurfaceResolver, Url, WorkspaceContext}
  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.{PreviewLauncher, Runtime}
  alias DevIDE.Terminals.{Tmux, TmuxTopology}
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias McpCtl.{Params, Tool}

  @type tool :: %{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  @doc "Tool definitions exposed to agent runtimes."
  @spec definitions() :: [tool()]
  def definitions do
    workspace_props = Params.preview_workspace_props()

    open_props =
      Params.preview_open_props()
      |> Map.put(:port, Params.port())
      |> Map.put(:anchor_pane_id, %{type: "string"})

    mode_param = %{
      type: "string",
      enum: ["app", "localhost", "here"],
      default: "app",
      description:
        "Which surface to open: \"app\" (the workspace app surface), \"localhost\" " <>
          "(a specific dev-server port — requires port), or \"here\" (the app surface " <>
          "beside the calling agent — requires tmux_session)."
    }

    open_unified_props = Map.put(open_props, :mode, mode_param)

    surface_props = Map.put(workspace_props, :tmux_session, Params.tmux_session())
    session_only = Tool.object(%{session_id: Params.session_id()}, [:session_id])

    visible_mutation_props = %{
      session_id: Params.session_id(),
      allow_headless: %{
        type: "boolean",
        description:
          "Allow the action to run only in the automation browser when no visible pane is registered."
      }
    }

    close_props =
      Tool.object(%{
        session_id: Params.session_id(),
        pane_id: %{type: "string"},
        tmux_session: Params.session()
      })

    [
      Tool.define(
        "preview_resolve_workspace",
        "Resolve a workspace_id from a manager id or a folder path. Use this when a preview " <>
          "tool reports workspace_not_found or when working from an attached local folder.",
        Tool.object(%{
          workspace_id: Params.preview_workspace_props(include_path: false)[:workspace_id],
          workspace_path: Params.workspace_path_param(),
          path: Params.workspace_path_param(),
          cwd: Params.workspace_path_param()
        })
      ),
      Tool.define(
        "preview_surfaces",
        "List discoverable preview surfaces for a workspace (manager URLs, " <>
          "metadata localhost ports, and ports detected from tmux terminal output). " <>
          "Pane-backed surfaces include separate server_active, pane_registered, " <>
          "operator_visible, and visibility fields; do not treat a surface as visible " <>
          "unless operator_visible/browser_loaded is true. Call before preview_open_app " <>
          "to pick a surface name.",
        Tool.object(surface_props, [:workspace_id])
      ),
      Tool.define(
        "preview_open",
        "Open a workspace preview. Pass mode to pick the surface: \"app\" (default) opens " <>
          "the workspace app surface and, on loopback DevIDE, auto-navigates to the " <>
          "workspace viewer (returns navigated_to / navigation_failed); \"localhost\" opens " <>
          "a specific dev-server port (requires port); \"here\" opens the app surface beside " <>
          "the calling agent (requires tmux_session, from a session-scoped endpoint or " <>
          "explicit argument). Opens preflight the target URL and reuse an existing pane by " <>
          "default. This is the preferred open tool; preview_open_app/_localhost/_here/" <>
          "_current_workspace remain as deprecated aliases.",
        Tool.object(open_unified_props, [:workspace_id])
      ),
      Tool.define(
        "preview_open_current_workspace",
        "Deprecated alias — prefer preview_open (mode app) on a pre-scoped endpoint. " <>
          "Open the pre-scoped current workspace app preview, auto-navigate to the DevIDE " <>
          "workspace viewer on loopback when available, and return the control session. " <>
          "On loopback, returns navigated_to on success or navigation_failed when open " <>
          "succeeded but viewer navigation was blocked.",
        Tool.object(Map.drop(open_props, [:workspace_id, :workspace_path]))
      ),
      Tool.define(
        "preview_open_here",
        "Deprecated alias — prefer preview_open(mode: \"here\"). " <>
          "Open the workspace app preview beside the calling agent. Requires tmux_session " <>
          "from a session-scoped Preview MCP endpoint or an explicit tmux_session argument.",
        Tool.object(open_props, [:workspace_id, :tmux_session])
      ),
      Tool.define(
        "preview_ensure_server_here",
        "Ensure the runtime-owned preview server for this scoped agent session is starting " <>
          "or running. This does not open a visible preview pane.",
        Tool.object(open_props, [:workspace_id, :tmux_session])
      ),
      Tool.define(
        "preview_open_app",
        "Deprecated alias — prefer preview_open(mode: \"app\"). " <>
          "Open the workspace app preview surface in a controllable session. On loopback " <>
          "DevIDE (app-local), auto-navigates to the workspace viewer route and returns " <>
          "navigated_to on success or navigation_failed when open succeeded but viewer " <>
          "navigation was blocked.",
        Tool.object(open_props, [:workspace_id])
      ),
      Tool.define(
        "preview_open_localhost",
        "Deprecated alias — prefer preview_open(mode: \"localhost\"). " <>
          "Open a localhost preview on a specific port (e.g. after serving static " <>
          "HTML with python -m http.server). When port is the DevIDE loopback port " <>
          "and path is /, opens /workspaces instead. Port must be in workspace metadata, " <>
          "a common dev port, or detected from terminal output.",
        Tool.object(
          Map.merge(open_props, %{port: Params.port(), path: Params.path()}),
          [:workspace_id, :port]
        )
      ),
      Tool.define(
        "preview_navigate",
        "Navigate within the allowed preview origin (relative path or same-origin URL).",
        Tool.object(%{session_id: Params.session_id(), path: %{type: "string"}}, [
          :session_id,
          :path
        ])
      ),
      Tool.define(
        "preview_navigate_pane",
        "Navigate an existing embedded preview pane by tmux pane id and update connected " <>
          "DevIDE viewers. Use this when a preview pane is already visible in the terminal.",
        Tool.object(%{pane_id: %{type: "string"}, path: %{type: "string"}}, [
          :pane_id,
          :path
        ])
      ),
      Tool.define(
        "preview_observe_pane",
        "Observe an existing DevIDE preview pane by tmux pane id. Returns URL/title, " <>
          "iframe vs snapshot mode, current status, latest screenshot artifact, and recent " <>
          "human/backend preview interactions.",
        Tool.object(
          Map.merge(workspace_props, %{
            pane_id: %{type: "string"},
            limit: %{type: "integer", minimum: 1, maximum: 50}
          }),
          [:workspace_id, :pane_id]
        )
      ),
      Tool.define(
        "preview_observe",
        "Observe the current preview page with static HTTP HTML fetch.",
        session_only
      ),
      Tool.define(
        "preview_observe_live",
        "Observe the current preview page through browser automation for post-hydration DOM state.",
        session_only
      ),
      Tool.define(
        "preview_click",
        "Click an element by CSS selector or viewport coordinates. Prefers the visible " <>
          "preview pane; falls back to an automation screenshot snapshot when direct " <>
          "visible control is unavailable.",
        Tool.object(
          Map.merge(visible_mutation_props, %{
            selector: Params.selector(),
            nth: Params.nth(),
            x: Params.x(),
            y: Params.y()
          }),
          [:session_id]
        )
      ),
      Tool.define(
        "preview_type",
        "Type text into an input matched by CSS selector. Prefers the visible preview " <>
          "pane; falls back to an automation screenshot snapshot when direct visible " <>
          "control is unavailable.",
        Tool.object(
          Map.merge(visible_mutation_props, %{
            selector: Params.selector(),
            nth: Params.nth(),
            text: Params.text()
          }),
          [:session_id, :selector, :text]
        )
      ),
      Tool.define(
        "preview_press",
        "Press a keyboard key in the preview session. Prefers the visible preview pane; " <>
          "falls back to an automation screenshot snapshot when direct visible control is unavailable.",
        Tool.object(Map.merge(visible_mutation_props, %{key: Params.key()}), [
          :session_id,
          :key
        ])
      ),
      Tool.define(
        "preview_screenshot",
        "Capture a screenshot artifact from the current preview page.",
        session_only
      ),
      Tool.define(
        "preview_close",
        "Close a preview by session_id or tmux pane_id. pane_id is preferred when cleaning " <>
          "up a visible or stale preview pane; pass tmux_session too when the pane is not " <>
          "registered in the current release.",
        close_props
      ),
      Tool.define(
        "preview_get_storage",
        "Return localStorage and sessionStorage for the current preview origin.",
        session_only
      ),
      Tool.define(
        "preview_clear_storage",
        "Clear cookies, localStorage, and sessionStorage for the current preview origin. " <>
          "For persistent storage profiles, also updates the saved profile to the cleared state.",
        session_only
      ),
      Tool.define(
        "preview_report_errors",
        "Return console and network errors from the latest observation.",
        session_only
      ),
      Tool.define(
        "preview_reload_iframe",
        "Ask connected DevIDE viewers for this workspace to reload the active embedded " <>
          "preview iframe. Best-effort broadcast; does not mutate the preview control session.",
        Tool.object(
          Map.merge(workspace_props, %{actor_id: Params.actor_id(), reason: %{type: "string"}}),
          [:workspace_id]
        )
      ),
      Tool.define(
        "devide_reload_page",
        "Ask connected DevIDE viewers for this workspace to reload the whole workspace page. " <>
          "The terminal should reattach through DevIDE's per-tab tmux session id.",
        Tool.object(
          Map.merge(workspace_props, %{actor_id: Params.actor_id(), reason: %{type: "string"}}),
          [:workspace_id]
        )
      )
    ]
  end

  @doc "Dispatch a named agent preview tool."
  @spec invoke(String.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def invoke(tool_name, workspace, params) when is_map(workspace) and is_map(params) do
    case tool_name do
      "preview_resolve_workspace" -> resolve_workspace(params)
      "preview_surfaces" -> surfaces(workspace, params)
      "preview_open" -> open_unified(workspace, params)
      "preview_open_current_workspace" -> open_app_preview(workspace, params)
      "preview_open_here" -> open_app_here(workspace, params)
      "preview_ensure_server_here" -> ensure_server_here(workspace, params)
      "preview_open_app" -> open_app_preview(workspace, params)
      "preview_open_localhost" -> open_localhost_preview(workspace, params)
      "preview_navigate" -> navigate(params)
      "preview_navigate_pane" -> navigate_pane(params)
      "preview_observe_pane" -> observe_pane(workspace, params)
      "preview_observe" -> observe(params)
      "preview_observe_live" -> observe_live(params)
      "preview_click" -> click(params)
      "preview_type" -> type(params)
      "preview_press" -> press(params)
      "preview_screenshot" -> screenshot(params)
      "preview_close" -> close(params)
      "preview_get_storage" -> get_storage(params)
      "preview_clear_storage" -> clear_storage(params)
      "preview_report_errors" -> report_errors(params)
      "preview_reload_iframe" -> reload_iframe(workspace, params)
      "devide_reload_page" -> reload_page(workspace, params)
      _ -> {:error, :unknown_tool}
    end
  end

  @doc "List discoverable preview surfaces for agent planning."
  @spec surfaces(map(), map()) :: {:ok, map()} | {:error, term()}
  def surfaces(workspace, params \\ %{}) when is_map(workspace) and is_map(params) do
    workspace = WorkspaceContext.prepare(workspace)
    active_by_origin = active_pane_registrations_by_origin(workspace)

    payload =
      workspace
      |> Previews.discover_surfaces(surface_resolver_opts(params, runtime_required: false))
      |> Enum.map(&surface_payload(&1, active_by_origin, params))
      |> Enum.sort_by(& &1.active, :desc)

    {:ok, %{surfaces: payload}}
  end

  # Index the live embedded preview panes for this workspace by origin so a
  # discovered surface can be tagged with the pane that is currently rendered
  # beside the user. Origin-only match tolerates path differences (a pane sitting
  # on /foo still resolves to its :5173 surface).
  defp active_panes_by_origin(workspace) do
    workspace
    |> active_pane_registrations_by_origin()
    |> Map.new(fn {origin, registration} -> {origin, registration.pane_id} end)
  end

  defp active_pane_registrations_by_origin(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) ->
        id
        |> PreviewPanes.list_for_workspace()
        |> Enum.reduce(%{}, fn registration, acc ->
          case registration_origin(registration) do
            nil -> acc
            origin -> Map.put_new(acc, origin, registration)
          end
        end)

      _ ->
        %{}
    end
  end

  @doc false
  def registration_origin(registration) do
    Url.origin_of(Map.get(registration, :display_url)) ||
      Url.origin_of(Map.get(registration, :url))
  end

  # Unified entry point for the preview_open tool. Routes by `mode` to the
  # existing per-surface handlers, which each validate their own required
  # arguments (localhost → port, here → tmux_session) and return structured
  # errors. The deprecated preview_open_app/_localhost/_here tools call those
  # same handlers directly.
  @valid_open_modes ~w(app localhost here)
  defp open_unified(workspace, params) do
    case string_param(params, :mode) || "app" do
      "app" -> open_app_preview(workspace, params)
      "localhost" -> open_localhost_preview(workspace, params)
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

    with {:ok, url} <- surface_url(workspace, surface, params),
         :ok <- ensure_unambiguous_tmux_session(workspace, params),
         opts <- split_opts(params, workspace),
         {:ok, result} <- open_or_split_preview_pane(workspace, url, opts),
         duplicate_cleanup <- cleanup_duplicate_preview_panes(workspace, url, result, opts),
         {:ok, navigation} <- maybe_navigate_to_workspace(workspace, result.session) do
      health = verify_preview_ready(result.session, navigation)

      operator_visibility =
        ensure_operator_preview_visible(workspace, result.registration, params, health)

      payload =
        session_payload(result.session, navigation)
        |> Map.put(:pane_id, result.pane_id)
        |> put_shared_registration(result.registration)
        |> Map.put(:health, health)
        |> Map.put(:visibility, operator_visibility.visibility)
        |> Map.put(:operator_visibility, operator_visibility_payload(operator_visibility))
        |> put_user_visibility(operator_visibility)
        |> maybe_put_reused(result)
        |> maybe_put_duplicate_cleanup(duplicate_cleanup)
        |> maybe_put_operator_focus(Map.get(operator_visibility, :focus))

      {:ok, payload}
    end
  end

  @doc "Open the app preview beside the calling agent."
  @spec open_app_here(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_app_here(workspace, params \\ %{}) do
    with session when is_binary(session) <- string_param(params, :tmux_session) do
      surface = Map.get(params, "surface", Map.get(params, :surface, "app"))

      params =
        params
        |> Map.put("tmux_session", session)
        |> Map.put("runtime_required", true)

      with {:ok, url} <- surface_url(workspace, surface, params),
           :ok <- ensure_unambiguous_tmux_session(workspace, params),
           {:ok, placement} <- resolve_preview_placement(session, params),
           opts <-
             split_opts(
               params
               |> Map.put("anchor_pane_id", placement.anchor_pane_id)
               |> Map.put("anchor_window_id", placement.anchor_window_id)
               |> Map.put("placement", placement.placement),
               workspace
             ),
           {:ok, result} <- open_or_split_preview_pane(workspace, url, opts),
           duplicate_cleanup <- cleanup_duplicate_preview_panes(workspace, url, result, opts),
           {:ok, navigation} <- maybe_navigate_to_workspace(workspace, result.session) do
        health = verify_preview_ready(result.session, navigation)

        operator_visibility =
          ensure_operator_preview_visible(workspace, result.registration, params, health)

        payload =
          session_payload(result.session, navigation)
          |> Map.put(:pane_id, result.pane_id)
          |> put_shared_registration(result.registration)
          |> Map.put(:health, health)
          |> Map.put(:visibility, operator_visibility.visibility)
          |> Map.put(:operator_visibility, operator_visibility_payload(operator_visibility))
          |> Map.put(:placement, placement_payload(result.registration))
          |> put_user_visibility(operator_visibility)
          |> maybe_put_reused(result)
          |> maybe_put_repaired_placement(result)
          |> maybe_put_duplicate_cleanup(duplicate_cleanup)
          |> maybe_put_operator_focus(Map.get(operator_visibility, :focus))

        {:ok, payload}
      end
    else
      _ -> {:error, missing_tmux_session_error()}
    end
  end

  @doc "Ensure the runtime-owned preview server for the scoped agent session."
  @spec ensure_server_here(map(), map()) :: {:ok, map()} | {:error, term()}
  def ensure_server_here(workspace, params \\ %{}) do
    with session when is_binary(session) <- string_param(params, :tmux_session),
         {:ok, %Runtime{} = runtime} <- runtime_for_tmux_session(workspace, session),
         %{} = preview_server <- Runtimes.runtime_preview_server(runtime),
         :ok <- PreviewLauncher.ensure_started(runtime) do
      {:ok,
       %{
         status: "queued",
         workspace_id: runtime.workspace_id,
         runtime_id: runtime.id,
         tmux_session: session,
         preview_server: preview_server
       }}
    else
      nil ->
        {:error, missing_tmux_session_error()}

      false ->
        {:error, :runtime_preview_server_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Open a localhost preview on an allowed port."
  @spec open_localhost_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_localhost_preview(workspace, params \\ %{}) when is_map(workspace) do
    with {:ok, port} <- parse_port(Map.get(params, "port") || Map.get(params, :port)),
         :ok <- WorkspaceContext.validate_port(WorkspaceContext.prepare(workspace), port),
         :ok <- ensure_unambiguous_tmux_session(workspace, params),
         path <- localhost_path(workspace, port, params),
         url = WorkspaceContext.localhost_url(port, path),
         opts <- split_opts(params, workspace),
         {:ok, result} <- open_or_split_preview_pane(workspace, url, opts),
         duplicate_cleanup <- cleanup_duplicate_preview_panes(workspace, url, result, opts) do
      health = verify_preview_ready(result.session, %{})

      operator_visibility =
        ensure_operator_preview_visible(workspace, result.registration, params, health)

      payload =
        session_payload(result.session)
        |> Map.put(:pane_id, result.pane_id)
        |> put_shared_registration(result.registration)
        |> Map.put(:health, health)
        |> Map.put(:visibility, operator_visibility.visibility)
        |> Map.put(:operator_visibility, operator_visibility_payload(operator_visibility))
        |> put_user_visibility(operator_visibility)
        |> maybe_put_reused(result)
        |> maybe_put_duplicate_cleanup(duplicate_cleanup)
        |> maybe_put_operator_focus(Map.get(operator_visibility, :focus))

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
         :ok <- preflight_preview_url(url, opts) do
      split_preview_pane(workspace, url, Keyword.put(opts, :preflight_done, true))
    end
  end

  defp open_owned_or_reused_preview_pane(workspace, url, opts) do
    case existing_preview_pane_for_url(workspace, url, opts) do
      {:ok, result} ->
        with :ok <- preflight_preview_url(url, opts) do
          {:ok, Map.put(result, :reused, true)}
        end

      {:misplaced, registration, mismatch} ->
        with :ok <- preflight_preview_url(url, opts),
             :ok <- repair_misplaced_preview_pane(registration),
             {:ok, result} <-
               split_preview_pane(workspace, url, Keyword.put(opts, :preflight_done, true)) do
          {:ok,
           result
           |> Map.put(:repaired_placement, true)
           |> Map.put(:placement_mismatch, mismatch)}
        end

      _ ->
        with :ok <- preflight_preview_url(url, opts) do
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
            nil -> nil
            origin -> workspace |> active_pane_registrations_by_origin() |> Map.get(origin)
          end)
      end

    case source do
      %{workspace_id: workspace_id} ->
        ensure_pane_workspace_scope(workspace, workspace_id)

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
              |> active_panes_by_origin()
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
         id when is_binary(id) <- workspace_id(workspace) do
      id
      |> PreviewPanes.list_for_workspace()
      |> Enum.find_value(fn registration ->
        if registration_matches_origin?(registration, origin) and
             registration.tmux_session == tmux_session and
             Map.get(registration, :anchor_window_id) == anchor_window_id do
          current_window_id =
            Map.get(registration, :pane_window_id) ||
              pane_window_id(tmux_session, registration.pane_id)

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
    registration_origin(registration) == origin or
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
        with origin when is_binary(origin) <- registration_origin(current) || Url.origin_of(url),
             id when is_binary(id) <- workspace_id(workspace) do
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
    kill_result = kill_preview_pane(registration.tmux_session, registration.pane_id)
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
  defp cleanup_result({:error, reason}), do: health_error(reason)
  defp cleanup_result(other), do: health_error(other)

  defp reuse_preview_pane(nil, _workspace, _url, _opts), do: :not_found

  defp reuse_preview_pane(pane_id, workspace, url, opts) do
    with %{
           workspace_id: registration_workspace_id,
           tmux_session: tmux_session
         } = registration <-
           PreviewPanes.get_by_pane(pane_id),
         :ok <- ensure_pane_workspace_scope(workspace, registration_workspace_id),
         :ok <- ensure_pane_tmux_session_scope(pane_id, opts),
         :ok <- ensure_pane_placement_scope(pane_id, opts),
         :ok <- ensure_tmux_pane_exists(tmux_session, pane_id) do
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
           Keyword.get(opts, :tmux_session) || resolve_tmux_session(workspace, opts) do
      panes = tmux_adapter().list_session_panes(tmux_session)

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
             tmux_adapter().capture_scrollback(tmux_session,
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
       (is_binary(command) and String.contains?(command, "devide-preview"))) and
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
    with :ok <- ensure_tmux_pane_exists(tmux_session, pane_id),
         {:ok, registration} <-
           PreviewPanes.register(%{
             "pane_id" => pane_id,
             "url" => url,
             "workspace" => workspace,
             "workspace_id" => workspace_id(workspace),
             "cwd" => Keyword.get(opts, :cwd) || workspace_host_path(workspace),
             "viewport" => viewport_string(Keyword.get(opts, :viewport)),
             "tmux_session" => tmux_session,
             "actor_id" => Keyword.get(opts, :actor_id),
             "default_headers" => Keyword.get(opts, :default_headers),
             "storage_profile" => Keyword.get(opts, :storage_profile),
             "storage_profile_name" => Keyword.get(opts, :storage_profile_name),
             "placement" => Keyword.get(opts, :placement),
             "anchor_pane_id" => Keyword.get(opts, :anchor_pane_id),
             "anchor_window_id" => Keyword.get(opts, :anchor_window_id),
             "pane_window_id" => pane_window_id(tmux_session, pane_id)
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
             "workspace_id" => workspace_id(workspace),
             "cwd" => Keyword.get(opts, :cwd) || workspace_host_path(workspace),
             "viewport" => viewport_string(Keyword.get(opts, :viewport)),
             "tmux_session" => registration.tmux_session || Keyword.get(opts, :tmux_session),
             "actor_id" => Keyword.get(opts, :actor_id),
             "default_headers" => Keyword.get(opts, :default_headers),
             "storage_profile" => Keyword.get(opts, :storage_profile),
             "storage_profile_name" => Keyword.get(opts, :storage_profile_name),
             "placement" => Keyword.get(opts, :placement),
             "anchor_pane_id" => Keyword.get(opts, :anchor_pane_id),
             "anchor_window_id" => Keyword.get(opts, :anchor_window_id),
             "pane_window_id" =>
               pane_window_id(
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

  defp put_user_visibility(payload, %{status: "confirmed"}),
    do:
      payload
      |> Map.put(:user_visible, true)
      |> Map.put(:operator_visible, true)
      |> Map.put(:preview_open_state, "visible")

  defp put_user_visibility(payload, %{visibility: visibility}),
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

  defp maybe_put_duplicate_cleanup(payload, []), do: payload

  defp maybe_put_duplicate_cleanup(payload, cleaned) when is_list(cleaned) do
    Map.put(payload, :duplicate_cleanup, %{removed_panes: cleaned})
  end

  defp maybe_put_operator_focus(payload, {:ok, focus}),
    do: Map.put(payload, :operator_focus, focus)

  defp maybe_put_operator_focus(payload, {:error, reason}),
    do: Map.put(payload, :operator_focus_error, reason)

  defp operator_visibility_payload(visibility) when is_map(visibility) do
    visibility
    |> Map.drop([:visibility, :focus])
    |> Enum.map(fn
      {key, {:ok, value}} -> {key, value}
      {key, {:error, reason}} -> {key, %{status: "error", reason: health_error(reason)}}
      entry -> entry
    end)
    |> Map.new()
  end

  defp verify_preview_ready(_session, %{navigation_failed: failure}) when not is_nil(failure) do
    %{
      ready: false,
      reason: :navigation_failed,
      navigation_failed: navigation_failure_payload(failure)
    }
  end

  defp verify_preview_ready(%{id: session_id}, _navigation) do
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
            |> Map.put(:reload_error, health_error(reason))
        end
    end
  end

  defp observe_preview_health(session_id) do
    case PreviewControl.observe_live(session_id) do
      {:ok, observation} ->
        errors = errors_payload(observation)
        console_errors = Map.get(errors, :console_errors, [])
        network_errors = Map.get(errors, :network_errors, [])

        %{
          ready: console_errors == [] and network_errors == [],
          reason: health_reason(console_errors, network_errors),
          url: observation_url(observation),
          title: observation |> dom_summary_title(),
          console_errors: console_errors,
          network_errors: network_errors
        }

      {:error, reason} ->
        %{ready: false, reason: :browser_observation_failed, observe_error: health_error(reason)}
    end
  end

  defp health_reason([], []), do: :ok
  defp health_reason(_console_errors, _network_errors), do: :browser_errors

  defp health_error(reason) when is_atom(reason), do: reason
  defp health_error(reason) when is_binary(reason), do: reason
  defp health_error(reason), do: inspect(reason)

  defp ensure_operator_preview_visible(workspace, registration, params, %{ready: true}) do
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
        {:error, reason} -> {:error, health_error(reason)}
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

  defp ensure_operator_preview_visible(_workspace, registration, _params, health) do
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
          confirmed_at: datetime_iso(entry.inserted_at),
          focus: focus,
          visibility: preview_visibility(registration, workspace_ids)
        }

      {:error, reason} ->
        %{
          status: "repair_failed",
          error: health_error(reason),
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

  defp preview_visibility_from_activity(activity) when is_list(activity) do
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
      browser_loaded_at: browser_loaded_at && datetime_iso(browser_loaded_at.inserted_at),
      operator_visible_state: state,
      diagnostic: preview_visibility_diagnostic(state, last_browser_event),
      last_browser_event: activity_payload(last_browser_event)
    }
  end

  defp preview_visibility_from_activity(_), do: preview_visibility_from_activity([])

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
      last_browser_event: activity_payload(event)
    }

  defp preview_visibility_diagnostic("iframe_error", event),
    do: %{
      reason: "iframe_error",
      next_action: "inspect_preview_proxy_or_network_errors",
      last_browser_event: activity_payload(event)
    }

  defp preview_visibility_diagnostic("src_assigned_no_load", event),
    do: %{
      reason: "iframe_src_assigned_but_not_loaded",
      next_action: "check_preview_proxy_auth_csp_or_upstream_response",
      last_browser_event: activity_payload(event)
    }

  defp preview_visibility_diagnostic("rendered_no_src", event),
    do: %{
      reason: "overlay_mounted_without_iframe_src_confirmation",
      next_action: "reload_preview_iframe_or_check_hook_dataset",
      last_browser_event: activity_payload(event)
    }

  defp preview_visibility_diagnostic(_state, _event),
    do: %{reason: "no_browser_preview_event", next_action: "verify_visible_workspace_and_pane"}

  defp fresh_browser_visibility_event?(%{inserted_at: %DateTime{} = inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :millisecond) <=
      preview_visibility_fresh_ms()
  end

  defp fresh_browser_visibility_event?(_), do: false

  defp loaded_browser_visibility_event?(%{event: "iframe_loaded"}), do: true

  defp loaded_browser_visibility_event?(%{event: "visibility_heartbeat", metadata: metadata})
       when is_map(metadata) do
    Map.get(metadata, "loaded") == true
  end

  defp loaded_browser_visibility_event?(_), do: false

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
    [workspace_id(workspace), Map.get(registration, :workspace_id)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.flat_map(&WorkspaceAliases.viewer_ids/1)
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

  @doc """
  Split the active tmux window and run `devide-preview` in the new pane.

  Options:
    * `:tmux_session` — required workspace tmux session name
    * `:cwd` — working directory for the split (defaults to workspace path)
    * `:viewport` — optional locked viewport (`WxH` string or map)
    * `:actor_id` — audit identity
  """
  @spec split_preview_pane(map(), String.t(), keyword()) ::
          {:ok, %{pane_id: String.t(), session: struct()}} | {:error, term()}
  def split_preview_pane(workspace, url, opts) when is_map(workspace) and is_binary(url) do
    tmux_session = resolve_tmux_session(workspace, opts)

    opts =
      opts
      |> Keyword.put_new(:tmux_session, tmux_session)
      |> Keyword.put_new(:workspace_id, workspace_id(workspace))

    with true <- is_binary(tmux_session) and tmux_session != "",
         :ok <- maybe_preflight_preview_url(url, opts),
         {:ok, split_target_pane_id} <- split_target_pane_id(tmux_session, opts),
         command <- preview_command(url, opts),
         {:ok, pane_id} <-
           tmux_adapter().split_pane(tmux_session, split_target_pane_id, "h",
             cwd: Keyword.get(opts, :cwd) || workspace_host_path(workspace),
             command: command
           ),
         :ok <- ensure_tmux_pane_exists(tmux_session, pane_id),
         # tmux focuses the new preview holder; restore the operator pane so
         # Ghostty keeps streaming shell output instead of devide-preview text.
         :ok <- tmux_adapter().select_pane(tmux_session, split_target_pane_id),
         {:ok, registration} <- await_pane_registration(pane_id, workspace, url, opts),
         :ok <- ensure_tmux_pane_exists(tmux_session, pane_id) do
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

  @doc "Navigate within the allowed preview origin."
  @spec navigate(map()) :: {:ok, map()} | {:error, term()}
  def navigate(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)),
         path when is_binary(path) <-
           Map.get(params, "path") || Map.get(params, :path) ||
             {:error, {:missing_argument, "path"}} do
      PreviewControl.navigate(id, path)
    end
  end

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
         mode: preview_mode(registration),
         status: preview_status(registration),
         snapshot_mode: preview_mode(registration) == "snapshot"
       }}
    end
  end

  @doc "Observe a registered preview pane and its recent interaction feed."
  @spec observe_pane(map(), map()) :: {:ok, map()} | {:error, term()}
  def observe_pane(workspace, params) when is_map(workspace) and is_map(params) do
    with pane_id when is_binary(pane_id) <-
           Map.get(params, "pane_id") || Map.get(params, :pane_id) ||
             {:error, {:missing_argument, "pane_id"}},
         %{workspace_id: registration_workspace_id} = registration <-
           PreviewPanes.get_by_pane(pane_id),
         :ok <- ensure_pane_workspace_scope(workspace, registration_workspace_id) do
      limit = activity_limit(Map.get(params, "limit") || Map.get(params, :limit))
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
      visibility = preview_visibility_from_activity(recent_activity)

      {:ok,
       %{
         pane_id: pane_id,
         workspace_id: registration.workspace_id,
         preview_id: registration.preview_id,
         session_id: session_id,
         url: registration.url,
         display_url: registration.display_url,
         source_url: pane_source_url(registration, latest_observation),
         title: preview_title(registration, latest_observation),
         mode: preview_mode(registration),
         status: preview_status(registration),
         tmux: tmux_presence(registration),
         placement: placement_payload(registration),
         snapshot_mode: preview_mode(registration) == "snapshot",
         visibility: visibility,
         browser_loaded: visibility.browser_loaded,
         browser_loaded_at: visibility.browser_loaded_at,
         operator_visible_state: visibility.operator_visible_state,
         latest_screenshot: observation_payload(latest_screenshot),
         latest_observation: observation_payload(latest_observation),
         last_interaction: activity_payload(latest_activity),
         recent_activity: Enum.map(recent_activity, &activity_payload/1)
       }}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Observe the current preview page."
  @spec observe(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe(id))

  def observe(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe(id))

  def observe(id) when is_integer(id), do: PreviewControl.observe(id)

  @doc "Observe the current preview page through the browser runtime."
  @spec observe_live(map() | integer()) :: {:ok, map()} | {:error, term()}
  def observe_live(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe_live(id))

  def observe_live(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.observe_live(id))

  def observe_live(id) when is_integer(id), do: PreviewControl.observe_live(id)

  @doc "Click in the preview session."
  @spec click(map()) :: {:ok, map()} | {:error, term()}
  def click(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      target =
        cond do
          selector = Map.get(params, "selector") || Map.get(params, :selector) ->
            maybe_put_nth(%{selector: selector}, params)

          x = Map.get(params, "x") || Map.get(params, :x) ->
            y = Map.get(params, "y") || Map.get(params, :y)
            %{x: x, y: y}

          true ->
            %{}
        end

      visible_or_fallback(id, "click", target, params, fn ->
        with {:ok, observation} <- PreviewControl.click(id, target) do
          {:ok, maybe_sync_pane_navigation(id, observation)}
        end
      end)
    end
  end

  @doc "Type into a preview input."
  @spec type(map()) :: {:ok, map()} | {:error, term()}
  def type(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      selector = Map.get(params, "selector") || Map.get(params, :selector)
      text = Map.get(params, "text") || Map.get(params, :text)
      opts = maybe_put_nth(%{}, params)

      target = Map.merge(%{selector: selector, text: text}, opts)

      visible_or_fallback(id, "type", target, params, fn ->
        with {:ok, observation} <- PreviewControl.type(id, selector, text, opts) do
          {:ok, maybe_sync_pane_navigation(id, observation)}
        end
      end)
    end
  end

  @doc "Press a key in the preview session."
  @spec press(map()) :: {:ok, map()} | {:error, term()}
  def press(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      key = Map.get(params, "key") || Map.get(params, :key)

      visible_or_fallback(id, "press", %{key: key}, params, fn ->
        with {:ok, observation} <- PreviewControl.press(id, key) do
          {:ok, maybe_sync_pane_navigation(id, observation)}
        end
      end)
    end
  end

  @doc "Capture a screenshot from the preview session."
  @spec screenshot(map() | integer()) :: {:ok, map()} | {:error, term()}
  def screenshot(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.screenshot(id))

  def screenshot(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.screenshot(id))

  def screenshot(id) when is_integer(id), do: PreviewControl.screenshot(id)

  @doc "Close a preview control session."
  @spec close(map() | integer()) :: {:ok, map()} | {:error, term()}
  def close(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: do_close(id))

  def close(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: do_close(id))

  def close(%{"pane_id" => pane_id} = params) when is_binary(pane_id) and pane_id != "",
    do: do_close_pane(pane_id, Map.get(params, "tmux_session"))

  def close(%{pane_id: pane_id} = params) when is_binary(pane_id) and pane_id != "",
    do: do_close_pane(pane_id, Map.get(params, :tmux_session))

  def close(id) when is_integer(id), do: do_close(id)

  def close(_params), do: {:error, {:missing_argument, "session_id or pane_id"}}

  @doc "Return preview origin localStorage and sessionStorage."
  @spec get_storage(map() | integer()) :: {:ok, map()} | {:error, term()}
  def get_storage(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(id) when is_integer(id), do: PreviewControl.get_storage(id)

  @doc "Clear storage for the current preview origin."
  @spec clear_storage(map() | integer()) :: {:ok, map()} | {:error, term()}
  def clear_storage(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.clear_storage(id))

  def clear_storage(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.clear_storage(id))

  def clear_storage(id) when is_integer(id), do: PreviewControl.clear_storage(id)

  @doc "Report browser console/network errors from the latest observation."
  @spec report_errors(map() | integer()) :: {:ok, map()} | {:error, term()}
  def report_errors(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: do_report_errors(id))

  def report_errors(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: do_report_errors(id))

  def report_errors(id) when is_integer(id), do: do_report_errors(id)

  @doc "Ask connected workspace viewers to reload the active preview iframe."
  @spec reload_iframe(map(), map()) :: {:ok, map()} | {:error, term()}
  def reload_iframe(workspace, params) when is_map(workspace) and is_map(params) do
    BrowserControl.reload_preview_iframe(workspace, browser_control_opts(params))
  end

  @doc "Ask connected workspace viewers to reload the whole DevIDE page."
  @spec reload_page(map(), map()) :: {:ok, map()} | {:error, term()}
  def reload_page(workspace, params) when is_map(workspace) and is_map(params) do
    BrowserControl.reload_page(workspace, browser_control_opts(params))
  end

  defp do_report_errors(session_id) do
    case PreviewControl.latest_errors(session_id) do
      %{console_errors: [], network_errors: []} ->
        report_errors_from_observation(session_id)

      errors ->
        {:ok, errors}
    end
  end

  defp visible_or_fallback(session_id, action, target, params, fallback_fun)
       when is_integer(session_id) and is_function(fallback_fun, 0) do
    registration = PreviewPanes.get_by_session(session_id)

    case try_visible_preview_action(registration, action, target, params) do
      {:ok, visible} ->
        {:ok, visible_action_payload(session_id, action, visible)}

      {:error, visible_error} ->
        with {:ok, observation} <- fallback_fun.() do
          {:ok,
           observation
           |> maybe_snapshot_visible_pane(session_id, registration)
           |> Map.put(:visible_effect, visible_fallback_effect(registration))
           |> Map.put(:visible_error, visible_error_payload(visible_error))
           |> Map.put(:headless_warning, headless_warning(registration, params))}
        end
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
              observation_payload(%{data: screenshot, artifact_path: artifact_path})
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
    if truthy_param?(params, :allow_headless) do
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
    current_url = observation_url(observation)

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

  defp observation_url(%{url: url}) when is_binary(url), do: url
  defp observation_url(%{"url" => url}) when is_binary(url), do: url
  defp observation_url(_), do: nil

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

  defp report_errors_from_observation(session_id) do
    case PreviewControl.latest_observation(session_id) do
      nil ->
        with {:ok, observation} <- PreviewControl.observe(session_id) do
          {:ok, errors_payload(observation)}
        end

      obs ->
        {:ok, errors_payload(obs.data)}
    end
  end

  defp do_close(session_id) do
    maybe_kill_preview_pane(session_id)

    with {:ok, session} <- PreviewControl.close_session(session_id) do
      {:ok, %{session_id: session.id, status: session.status}}
    end
  end

  defp do_close_pane(pane_id, tmux_session) do
    case PreviewPanes.get_by_pane(pane_id) do
      %{control_session_id: session_id, tmux_session: registered_tmux_session} = registration ->
        kill_result = kill_preview_pane(registered_tmux_session || tmux_session, pane_id)
        deregister_result = PreviewPanes.deregister(pane_id)

        {:ok,
         %{
           pane_id: pane_id,
           session_id: session_id,
           preview_id: registration.preview_id,
           workspace_id: registration.workspace_id,
           status: :closed,
           tmux_kill: close_result_payload(kill_result),
           deregister: close_result_payload(deregister_result)
         }}

      nil when is_binary(tmux_session) and tmux_session != "" ->
        {:ok,
         %{
           pane_id: pane_id,
           status: :closed,
           stale: true,
           tmux_session: tmux_session,
           tmux_kill: close_result_payload(kill_preview_pane(tmux_session, pane_id))
         }}

      nil ->
        {:error,
         %{
           error: :preview_pane_not_registered,
           pane_id: pane_id,
           message:
             "Preview pane is not registered in this release. Pass tmux_session to close a stale tmux pane."
         }}
    end
  end

  defp tmux_presence(%{tmux_session: tmux_session, pane_id: pane_id})
       when is_binary(tmux_session) and tmux_session != "" and is_binary(pane_id) do
    %{
      session: tmux_session,
      pane_id: pane_id,
      present: tmux_pane_exists?(tmux_session, pane_id)
    }
  end

  defp tmux_presence(%{pane_id: pane_id}) do
    %{pane_id: pane_id, present: nil}
  end

  defp surface_url(workspace, surface, params) do
    opts =
      params
      |> surface_resolver_opts(runtime_required: truthy_param?(params, :runtime_required))

    case SurfaceResolver.resolve_open_surface(WorkspaceContext.prepare(workspace), surface, opts) do
      {:ok, %Surface{url: url}} when is_binary(url) -> {:ok, url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :surface_not_found}
    end
  end

  defp maybe_kill_preview_pane(session_id) do
    case PreviewPanes.get_by_session(session_id) do
      %{pane_id: pane_id, tmux_session: tmux_session}
      when is_binary(tmux_session) and is_binary(pane_id) ->
        _ = kill_preview_pane(tmux_session, pane_id)
        _ = PreviewPanes.deregister(pane_id)
        :ok

      _ ->
        :ok
    end
  end

  defp kill_preview_pane(tmux_session, pane_id)
       when is_binary(tmux_session) and tmux_session != "" and is_binary(pane_id) and
              pane_id != "" do
    tmux_adapter().kill_pane(tmux_session, pane_id)
  end

  defp kill_preview_pane(_tmux_session, _pane_id), do: {:error, :tmux_session_required}

  defp close_result_payload(:ok), do: %{status: "ok"}
  defp close_result_payload({:ok, value}), do: %{status: "ok", value: inspect(value)}

  defp close_result_payload({:error, reason}),
    do: %{status: "error", reason: health_error(reason)}

  defp close_result_payload(other), do: %{status: "unknown", result: inspect(other)}

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
        tmux_session = Keyword.get(opts, :tmux_session) || workspace_tmux_session(workspace)

        with :ok <- ensure_tmux_pane_exists(tmux_session, pane_id) do
          PreviewPanes.register(%{
            "pane_id" => pane_id,
            "url" => url,
            "workspace" => workspace,
            "workspace_id" => workspace_id(workspace),
            "cwd" => Keyword.get(opts, :cwd) || workspace_host_path(workspace),
            "viewport" => viewport_string(Keyword.get(opts, :viewport)),
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
            "pane_window_id" => pane_window_id(tmux_session, pane_id)
          })
        end
    end
  end

  defp ensure_tmux_pane_exists(tmux_session, pane_id)
       when is_binary(tmux_session) and is_binary(pane_id) do
    if tmux_pane_exists?(tmux_session, pane_id) do
      :ok
    else
      _ = PreviewPanes.deregister(pane_id)

      {:error,
       %{
         error: :preview_pane_exited,
         pane_id: pane_id,
         tmux_session: tmux_session,
         message: "Preview pane exited before it could be shown; no preview pane was opened."
       }}
    end
  end

  defp ensure_tmux_pane_exists(_tmux_session, _pane_id), do: :ok

  defp tmux_pane_exists?(tmux_session, pane_id) do
    tmux_session
    |> tmux_adapter().list_session_panes()
    |> Enum.any?(&(Map.get(&1, :id) == pane_id))
  end

  defp maybe_preflight_preview_url(url, opts) do
    if Keyword.get(opts, :preflight_done) == true do
      :ok
    else
      preflight_preview_url(url, opts)
    end
  end

  defp preflight_preview_url(url, opts) do
    if preview_preflight_enabled?(opts) do
      do_preflight_preview_url(url, opts)
    else
      :ok
    end
  end

  defp preview_preflight_enabled?(opts) do
    Keyword.get(opts, :preflight) ||
      Application.get_env(:dev_ide, :preview_open_preflight, true)
  end

  defp do_preflight_preview_url(url, opts) when is_binary(url) do
    headers = Keyword.get(opts, :default_headers) || %{}
    timeout = Application.get_env(:dev_ide, :preview_open_preflight_timeout_ms, 1_500)

    case Req.get(url,
           headers: headers,
           redirect: false,
           retry: false,
           connect_options: [timeout: timeout],
           receive_timeout: timeout
         ) do
      {:ok, %{status: status}} when status in 200..399 or status in [401, 403] ->
        :ok

      {:ok, %{status: status}} ->
        {:error,
         %{
           error: :preview_http_status,
           url: url,
           status: status,
           message: "Preview URL responded with HTTP #{status}; no preview pane was opened."
         }}

      {:error, reason} ->
        {:error,
         %{
           error: :preview_unreachable,
           url: url,
           reason: preview_preflight_reason(reason),
           message: "Preview URL is unreachable; no preview pane was opened."
         }}
    end
  end

  defp do_preflight_preview_url(url, _opts) do
    {:error,
     %{
       error: :invalid_preview_url,
       url: inspect(url),
       message: "Preview URL must be a string; no preview pane was opened."
     }}
  end

  defp preview_preflight_reason(%{reason: reason}), do: reason
  defp preview_preflight_reason(reason), do: inspect(reason)

  defp split_target_pane_id(tmux_session, opts) do
    case Keyword.get(opts, :anchor_pane_id) do
      pane_id when is_binary(pane_id) and pane_id != "" ->
        {:ok, pane_id}

      _ ->
        active_split_target_pane_id(tmux_session)
    end
  end

  defp active_split_target_pane_id(tmux_session) do
    topology = TmuxTopology.get(tmux_session, tmux: tmux_adapter())
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
    viewport = viewport_string(Keyword.get(opts, :viewport))

    []
    |> maybe_add_preview_env("DEV_IDE_API_TOKEN", preview_api_token())
    |> maybe_add_preview_env("DEVIDE_URL", preview_api_base_url())
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
    |> Kernel.++([preview_cli_executable(), shell_quote(url)])
    |> maybe_add_viewport_arg(viewport)
    |> maybe_add_share_arg(Keyword.get(opts, :share_session))
    |> maybe_add_attach_to_pane_arg(Keyword.get(opts, :attach_to_pane_id))
    |> Enum.join(" ")
  end

  defp maybe_add_preview_env(parts, _key, nil), do: parts
  defp maybe_add_preview_env(parts, _key, ""), do: parts
  defp maybe_add_preview_env(parts, key, value), do: parts ++ ["#{key}=#{shell_quote(value)}"]

  defp maybe_add_viewport_arg(parts, nil), do: parts
  defp maybe_add_viewport_arg(parts, ""), do: parts

  defp maybe_add_viewport_arg(parts, viewport),
    do: parts ++ ["--viewport", shell_quote(viewport)]

  defp maybe_add_share_arg(parts, true), do: parts ++ ["--share"]
  defp maybe_add_share_arg(parts, _), do: parts

  defp maybe_add_attach_to_pane_arg(parts, nil), do: parts
  defp maybe_add_attach_to_pane_arg(parts, ""), do: parts

  defp maybe_add_attach_to_pane_arg(parts, pane_id),
    do: parts ++ ["--attach-to-pane", shell_quote(pane_id)]

  defp preview_cli_executable do
    case Application.get_env(:dev_ide, :devide_preview_script) do
      path when is_binary(path) and path != "" ->
        shell_quote(path)

      _ ->
        case :code.priv_dir(:dev_ide) do
          dir when is_list(dir) ->
            dir
            |> List.to_string()
            |> Path.join("scripts/devide-preview")
            |> shell_quote()

          _ ->
            "devide-preview"
        end
    end
  end

  defp preview_api_token do
    System.get_env("DEV_IDE_API_TOKEN") ||
      Application.get_env(:dev_ide, :dev_ide_api_token)
  end

  defp preview_api_base_url do
    cond do
      url = System.get_env("DEVIDE_URL") ->
        url

      host = System.get_env("PHX_HOST") ->
        "https://#{host}"

      true ->
        nil
    end
  end

  defp split_opts(params, workspace) do
    tmux_session =
      string_param(params, :tmux_session) ||
        resolve_tmux_session(workspace, Map.new(params))

    tool_opts(params, workspace)
    |> Keyword.merge(
      tmux_session: tmux_session,
      workspace_id: workspace_id(workspace),
      cwd: Map.get(params, "cwd") || Map.get(params, :cwd) || workspace_host_path(workspace),
      anchor_pane_id: Map.get(params, "anchor_pane_id") || Map.get(params, :anchor_pane_id),
      anchor_window_id: Map.get(params, "anchor_window_id") || Map.get(params, :anchor_window_id),
      placement: Map.get(params, "placement") || Map.get(params, :placement),
      viewport: Map.get(params, "viewport") || Map.get(params, :viewport)
    )
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp workspace_tmux_session(workspace) do
    workspace
    |> workspace_matching_sessions()
    |> pick_workspace_session()
  end

  defp runtime_for_tmux_session(workspace, tmux_session) do
    workspace_id = workspace_id(workspace)

    %{"workspace_id" => workspace_id}
    |> Runtimes.list_runtimes()
    |> Enum.find(fn %Runtime{} = runtime ->
      runtime.tmux_session_id == tmux_session and runtime.status not in ["cleaned", "expired"]
    end)
    |> case do
      %Runtime{} = runtime ->
        {:ok, runtime}

      _ ->
        {:error,
         %{
           error: :runtime_surface_not_found,
           tmux_session: tmux_session,
           workspace_id: workspace_id,
           message:
             "No runtime preview server is registered for this tmux_session. Report the worktree runtime before opening a runtime preview."
         }}
    end
  end

  defp ensure_unambiguous_tmux_session(workspace, params) do
    if string_param(params, :tmux_session) do
      :ok
    else
      case workspace_matching_sessions(workspace) do
        [_session] -> :ok
        [] -> :ok
        sessions -> {:error, ambiguous_tmux_session_error(sessions)}
      end
    end
  end

  defp workspace_matching_sessions(workspace) do
    workspace
    |> workspace_session_prefixes()
    |> then(fn prefixes ->
      tmux_adapter().list_sessions()
      |> Enum.filter(fn %{session: name} ->
        Enum.any?(prefixes, &String.starts_with?(name, &1))
      end)
    end)
  end

  defp pick_workspace_session([]), do: nil

  defp pick_workspace_session([%{session: session}]), do: session

  defp pick_workspace_session(sessions) do
    sessions
    |> Enum.sort_by(
      fn session ->
        attached_rank = if Map.get(session, :attached, false), do: 0, else: 1
        activity = Map.get(session, :activity, 0)
        {attached_rank, -activity, session.session}
      end,
      :asc
    )
    |> hd()
    |> Map.fetch!(:session)
  end

  defp missing_tmux_session_error do
    %{
      error: :missing_tmux_session,
      message:
        "Pass tmux_session or use the session-scoped Preview MCP URL for the calling agent.",
      guidance:
        "Use the session-scoped MCP endpoint so tmux_session is injected automatically, or pass tmux_session from terminal_list_sessions."
    }
  end

  defp ambiguous_tmux_session_error(sessions) do
    session_names =
      sessions
      |> Enum.map(& &1.session)
      |> Enum.sort()

    %{
      error: :ambiguous_tmux_session,
      ambiguous: true,
      candidate_session_names: session_names,
      candidate_sessions: Enum.map(sessions, &tmux_session_candidate/1),
      message:
        "Multiple tmux sessions match this workspace. Pass tmux_session or use the session-scoped Preview MCP URL for the calling agent.",
      guidance:
        "Use preview_open_here from a session-scoped MCP endpoint, or pass one of candidate_session_names as tmux_session."
    }
  end

  defp tmux_session_candidate(%{session: name} = session) do
    %{
      session: name,
      attached: Map.get(session, :attached),
      activity: Map.get(session, :activity)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp workspace_session_prefixes(workspace) do
    id = workspace_id(workspace)

    prefixes =
      if is_binary(id) and id != "" do
        [Tmux.workspace_session_prefix(id)]
      else
        []
      end

    case Workspaces.get(id) do
      {:ok, ws} ->
        for candidate <- [ws.name, ws.id], is_binary(candidate), candidate != "" do
          Tmux.workspace_session_prefix(candidate)
        end
        |> Enum.concat(prefixes)
        |> Enum.uniq()

      _ ->
        prefixes
    end
  end

  defp workspace_host_path(workspace) do
    case Workspaces.safe_host_path(workspace) do
      {:ok, path} -> path
      _ -> nil
    end
  end

  defp viewport_string(%{width: width, height: height})
       when is_integer(width) and is_integer(height),
       do: "#{width}x#{height}"

  defp viewport_string(viewport) when is_binary(viewport), do: viewport
  defp viewport_string(_), do: nil

  defp resolve_tmux_session(workspace, opts) when is_list(opts) do
    if Keyword.has_key?(opts, :tmux_session) do
      Keyword.get(opts, :tmux_session)
    else
      workspace_tmux_session(workspace)
    end
  end

  defp resolve_tmux_session(workspace, opts) when is_map(opts) do
    cond do
      Map.has_key?(opts, :tmux_session) -> Map.get(opts, :tmux_session)
      Map.has_key?(opts, "tmux_session") -> Map.get(opts, "tmux_session")
      true -> workspace_tmux_session(workspace)
    end
  end

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  defp shell_quote(value) when is_binary(value) do
    if String.match?(value, ~r"^[A-Za-z0-9_.,:/%@+-]+$") do
      value
    else
      "'" <> String.replace(value, "'", "'\\''") <> "'"
    end
  end

  defp errors_payload(data) when is_map(data) do
    %{
      console_errors:
        Map.get(data, "console_errors") || Map.get(data, :console_errors) ||
          Map.get(data, "errors") || Map.get(data, :errors) || [],
      network_errors: Map.get(data, "network_errors") || Map.get(data, :network_errors) || []
    }
  end

  defp ensure_pane_workspace_scope(workspace, registration_workspace_id) do
    workspace
    |> workspace_id()
    |> case do
      id when is_binary(id) and id != "" ->
        if registration_workspace_id in WorkspaceAliases.viewer_ids(id),
          do: :ok,
          else: {:error, :not_found}

      _ ->
        :ok
    end
  end

  defp ensure_pane_tmux_session_scope(pane_id, opts) do
    case Keyword.get(opts, :tmux_session) do
      session when is_binary(session) and session != "" ->
        case PreviewPanes.get_by_pane(pane_id) do
          %{tmux_session: ^session} -> :ok
          _ -> {:error, :not_found}
        end

      _ ->
        :ok
    end
  end

  defp ensure_pane_placement_scope(pane_id, opts) do
    case {Keyword.get(opts, :tmux_session), Keyword.get(opts, :anchor_window_id)} do
      {tmux_session, anchor_window_id}
      when is_binary(tmux_session) and tmux_session != "" and is_binary(anchor_window_id) and
             anchor_window_id != "" ->
        current_window_id = pane_window_id(tmux_session, pane_id)

        if current_window_id in [nil, anchor_window_id] do
          :ok
        else
          registration = PreviewPanes.get_by_pane(pane_id)

          {:error,
           {:preview_misplaced, registration,
            %{
              pane_id: pane_id,
              current_window_id: current_window_id,
              expected_window_id: anchor_window_id
            }}}
        end

      _ ->
        :ok
    end
  end

  defp repair_misplaced_preview_pane(%{pane_id: pane_id, tmux_session: tmux_session})
       when is_binary(pane_id) and is_binary(tmux_session) do
    _ = kill_preview_pane(tmux_session, pane_id)
    _ = PreviewPanes.deregister(pane_id)
    :ok
  end

  defp repair_misplaced_preview_pane(_), do: :ok

  defp resolve_preview_placement(tmux_session, params) do
    case string_param(params, :anchor_pane_id) do
      pane_id when is_binary(pane_id) ->
        {:ok,
         %{
           placement: "beside_agent",
           anchor_pane_id: pane_id,
           anchor_window_id: pane_window_id(tmux_session, pane_id),
           anchor_match: "explicit"
         }}

      _ ->
        with {:ok, pane} <-
               AgentPane.find(tmux_session, tmux_adapter(), allow_process_fallback: true) do
          {:ok,
           %{
             placement: "beside_agent",
             anchor_pane_id: pane.id,
             anchor_window_id: pane_window_id(tmux_session, pane.id) || Map.get(pane, :window_id),
             anchor_match: Map.get(pane, :agent_match)
           }}
        end
    end
  end

  defp pane_window_id(tmux_session, pane_id)
       when is_binary(tmux_session) and is_binary(pane_id) do
    tmux_session
    |> tmux_adapter().list_session_panes()
    |> Enum.find(&(Map.get(&1, :id) == pane_id))
    |> case do
      %{window_id: window_id} -> window_id
      %{"window_id" => window_id} -> window_id
      _ -> nil
    end
  end

  defp pane_window_id(_tmux_session, _pane_id), do: nil

  defp placement_payload(registration) when is_map(registration) do
    %{
      placement: Map.get(registration, :placement),
      anchor_pane_id: Map.get(registration, :anchor_pane_id),
      anchor_window_id: Map.get(registration, :anchor_window_id),
      pane_id: Map.get(registration, :pane_id),
      pane_window_id: Map.get(registration, :pane_window_id)
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp activity_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(50)

  defp activity_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, ""} -> activity_limit(int)
      _ -> 10
    end
  end

  defp activity_limit(_), do: 10

  defp snapshot_display_url?(display_url) when is_binary(display_url) do
    String.contains?(display_url, "/preview-artifacts/")
  end

  defp snapshot_display_url?(_), do: false

  defp preview_mode(%{display_url: display_url}) when is_binary(display_url) do
    if snapshot_display_url?(display_url), do: "snapshot", else: "iframe"
  end

  defp preview_mode(_), do: "unknown"

  defp preview_status(registration) do
    case preview_mode(registration) do
      "snapshot" -> "snapshot_controlled"
      "iframe" -> "iframe_live"
      _ -> "unknown"
    end
  end

  defp preview_title(registration, latest_observation) do
    dom_title =
      latest_observation
      |> observation_data()
      |> dom_summary_title()

    cond do
      is_binary(dom_title) and dom_title != "" ->
        dom_title

      is_binary(registration.display_url) and registration.display_url != "" ->
        Previews.extract_title_from_url(registration.display_url)

      true ->
        "Preview"
    end
  end

  defp dom_summary_title(%{"dom_summary" => %{"title" => title}}), do: title
  defp dom_summary_title(%{dom_summary: %{title: title}}), do: title
  defp dom_summary_title(%{"title" => title}), do: title
  defp dom_summary_title(%{title: title}), do: title
  defp dom_summary_title(_), do: nil

  # The real site behind a snapshot pane: prefer the URL we resolved and stored
  # at capture time, falling back to the `<base href>`/canonical we parsed from a
  # statically-served HTML capture (e.g. the durable preview demo).
  defp pane_source_url(registration, latest_observation) do
    case Map.get(registration, :source_url) do
      source_url when is_binary(source_url) and source_url != "" ->
        source_url

      _ ->
        latest_observation
        |> observation_data()
        |> dom_summary_source_url()
    end
  end

  defp dom_summary_source_url(%{"dom_summary" => %{"source_url" => url}}), do: url
  defp dom_summary_source_url(%{dom_summary: %{source_url: url}}), do: url
  defp dom_summary_source_url(%{"source_url" => url}), do: url
  defp dom_summary_source_url(%{source_url: url}), do: url
  defp dom_summary_source_url(_), do: nil

  defp observation_payload(nil), do: nil

  defp observation_payload(observation) do
    %{
      kind: Map.get(observation, :kind),
      data: observation_data(observation),
      artifact_path: Map.get(observation, :artifact_path),
      inserted_at: datetime_iso(Map.get(observation, :inserted_at))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, %{}] end)
    |> Map.new()
  end

  defp observation_data(nil), do: %{}
  defp observation_data(%{data: data}) when is_map(data), do: data
  defp observation_data(_), do: %{}

  defp activity_payload(nil), do: nil

  defp activity_payload(activity) do
    %{
      id: activity.id,
      pane_id: activity.pane_id,
      session_id: activity.session_id,
      preview_id: activity.preview_id,
      source: Atom.to_string(activity.source),
      event: activity.event,
      summary: activity.summary,
      metadata: activity.metadata,
      inserted_at: datetime_iso(activity.inserted_at)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp datetime_iso(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp datetime_iso(%NaiveDateTime{} = datetime),
    do: datetime |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()

  defp datetime_iso(_), do: nil

  defp session_payload(session, navigation \\ %{}) do
    navigation = navigation || %{}
    navigated_to = Map.get(navigation, :navigated_to)

    payload = %{
      session_id: session.id,
      workspace_id: session.workspace_id,
      preview_id: session.preview_id,
      surface: session.surface,
      current_url: navigated_to || session.current_url,
      display_url: session.metadata["display_url"],
      mode:
        if(snapshot_display_url?(session.metadata["display_url"]), do: "snapshot", else: "iframe"),
      snapshot_mode: snapshot_display_url?(session.metadata["display_url"]),
      adapter: session.adapter
    }

    payload
    |> maybe_put_navigated_to(Map.get(navigation, :navigated_to))
    |> maybe_put_navigation_failed(Map.get(navigation, :navigation_failed))
  end

  defp maybe_put_navigated_to(payload, navigated_to)
       when is_binary(navigated_to) and navigated_to != "" do
    Map.put(payload, :navigated_to, navigated_to)
  end

  defp maybe_put_navigated_to(payload, _), do: payload

  defp maybe_put_navigation_failed(payload, failed) when not is_nil(failed) do
    Map.put(payload, :navigation_failed, navigation_failure_payload(failed))
  end

  defp maybe_put_navigation_failed(payload, _), do: payload

  defp maybe_navigate_to_workspace(workspace, session) do
    if loopback_devide_session?(session) do
      route = workspace_viewer_route(workspace)

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

  defp navigation_failure_payload({:redirect_blocked, status, location}) do
    %{error: :redirect_blocked, status: status, location: location}
  end

  defp navigation_failure_payload({:http_status, status, body}) do
    %{error: :http_status, status: status, body: body}
  end

  defp navigation_failure_payload(reason) when is_map(reason), do: reason

  defp navigation_failure_payload(reason) when is_atom(reason), do: %{error: reason}

  defp navigation_failure_payload(reason), do: %{error: :navigation_failed, reason: reason}

  defp loopback_devide_session?(%{current_url: url}) when is_binary(url),
    do: devide_loopback_url?(url)

  defp loopback_devide_session?(_), do: false

  defp devide_loopback_url?(url) do
    port = Application.get_env(:dev_ide, :preview_loopback_port, 4000)

    Url.localhost_url?(url) and
      case URI.parse(url) do
        %URI{port: ^port} -> true
        %URI{port: nil} when port in [80, 443] -> true
        _ -> false
      end
  end

  defp workspace_viewer_route(workspace) do
    case workspace_id(workspace) do
      id when is_binary(id) and id != "" -> WorkspaceAliases.viewer_route_id(id)
      _ -> "/workspaces"
    end
  end

  defp workspace_id(workspace) when is_map(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  defp workspace_id(_), do: nil

  defp localhost_path(_workspace, port, params) do
    path = Map.get(params, "path", Map.get(params, :path, "/"))
    loopback_port = Application.get_env(:dev_ide, :preview_loopback_port, 4000)

    if port == loopback_port and path in ["/", ""] do
      "/workspaces"
    else
      path
    end
  end

  defp tool_opts(params, workspace) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      assignment_id: Map.get(params, "assignment_id") || Map.get(params, :assignment_id),
      tmux_session: string_param(params, :tmux_session),
      default_headers: default_headers(params, workspace),
      new_control_session: boolean_param(params, :new_control_session),
      force_new_pane: boolean_param(params, :force_new_pane),
      isolation_key: string_param(params, :isolation_key),
      storage_profile: storage_profile_param(params),
      storage_profile_name: string_param(params, :storage_profile_name),
      share_session: boolean_param(params, :share_session),
      attach_to_pane_id: string_param(params, :attach_to_pane_id)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp surface_resolver_opts(params, opts) do
    [
      tmux_session: string_param(params, :tmux_session),
      runtime_id: string_param(params, :runtime_id),
      port: port_param(params),
      runtime_required: Keyword.get(opts, :runtime_required, false)
    ]
    |> Enum.reject(fn
      {_key, value} when value in [nil, "", false] -> true
      _ -> false
    end)
  end

  defp port_param(params) when is_map(params) do
    case Map.get(params, "port") || Map.get(params, :port) do
      nil -> nil
      value -> with({:ok, port} <- parse_port(value), do: port)
    end
  end

  defp truthy_param?(params, key) when is_map(params) and is_atom(key),
    do: boolean_param(params, key) == true

  defp storage_profile_param(params) do
    case string_param(params, :storage_profile) do
      value when value in ["ephemeral", "workspace", "profile"] -> value
      _ -> nil
    end
  end

  defp boolean_param(params, key) when is_map(params) and is_atom(key) do
    value = Map.get(params, Atom.to_string(key)) || Map.get(params, key)

    case value do
      value when value in [true, false] -> value
      value when value in ["true", "1", "yes"] -> true
      value when value in ["false", "0", "no"] -> false
      _ -> nil
    end
  end

  defp string_param(params, key) when is_map(params) and is_atom(key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp browser_control_opts(params) do
    [
      actor_id: Map.get(params, "actor_id") || Map.get(params, :actor_id),
      reason: Map.get(params, "reason") || Map.get(params, :reason)
    ]
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp resolve_workspace(params) when is_map(params) do
    cond do
      id = Map.get(params, "workspace_id") || Map.get(params, :workspace_id) ->
        workspace_payload(id)

      path = workspace_path(params) ->
        path
        |> Workspaces.attach_folder()
        |> case do
          {:ok, workspace} -> {:ok, workspace_resolution_payload(workspace)}
          {:error, reason} -> {:error, workspace_path_error(path, reason)}
        end

      true ->
        {:error,
         %{
           error: :missing_workspace_reference,
           message:
             "Pass workspace_id or workspace_path. Generated DevIDE MCP URLs inject workspace_id automatically.",
           folder_id_format: "folder:<base64url-absolute-path>"
         }}
    end
  end

  defp workspace_payload(id) when is_binary(id) do
    case Workspaces.get(id) do
      {:ok, workspace} -> {:ok, workspace_resolution_payload(workspace)}
      {:error, reason} -> {:error, workspace_id_error(id, reason)}
    end
  end

  defp workspace_resolution_payload(workspace) do
    %{
      workspace_id: workspace.id,
      name: workspace.name,
      path: workspace.path,
      attached_folder: get_in(workspace.metadata || %{}, [:attached_folder]) == true,
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_path(params),
    do:
      Map.get(params, "workspace_path") || Map.get(params, :workspace_path) ||
        Map.get(params, "path") || Map.get(params, :path) || Map.get(params, "cwd") ||
        Map.get(params, :cwd)

  defp workspace_id_error(id, reason) do
    %{
      error: :workspace_not_found,
      workspace_id: id,
      reason: reason,
      message:
        "Workspace #{inspect(id)} was not found. For attached folders, pass workspace_path or use folder:<base64url-absolute-path>.",
      folder_id_format: "folder:<base64url-absolute-path>"
    }
  end

  defp workspace_path_error(path, reason) do
    %{
      error: :workspace_path_not_resolved,
      path: path,
      reason: reason,
      message: "Workspace path #{inspect(path)} could not be attached or is outside allowed roots"
    }
  end

  defp default_headers(params, workspace) do
    case Map.get(params, "default_headers") || Map.get(params, :default_headers) do
      headers when is_map(headers) ->
        sanitize_headers(headers)

      _ ->
        case workspace do
          ws when is_map(ws) -> Workspaces.forward_auth_headers(ws)
          _ -> nil
        end
    end
  end

  defp sanitize_headers(headers) do
    headers
    |> Enum.flat_map(fn {key, value} ->
      key = to_string(key)

      cond do
        key == "" -> []
        String.contains?(key, ["\r", "\n", ":"]) -> []
        not is_binary(value) -> []
        String.contains?(value, ["\r", "\n"]) -> []
        true -> [{key, value}]
      end
    end)
    |> Enum.take(20)
    |> Map.new()
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_session_id}
    end
  end

  defp parse_id(_), do: {:error, :invalid_session_id}

  # Thread an optional 0-based `nth` into the target/opts map when it is a
  # non-negative integer; ignore/strip any other value so a selector-only call
  # still produces a valid command.
  defp maybe_put_nth(map, params) do
    case Map.get(params, "nth") || Map.get(params, :nth) do
      nth when is_integer(nth) and nth >= 0 -> Map.put(map, :nth, nth)
      _ -> map
    end
  end

  defp parse_port(port) when is_integer(port), do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_port(_), do: {:error, :invalid_port}

  defp surface_payload(%Surface{} = surface, active_by_origin, params) do
    registration = Map.get(active_by_origin, Url.origin_of(surface.url))
    pane_id = registration && registration.pane_id
    visibility = surface_visibility(registration)
    operator_visible = visibility.browser_loaded == true

    %{
      name: surface.name,
      url: surface.url,
      title: surface.title,
      port: surface.port,
      source: Atom.to_string(surface.source),
      runtime_id: surface.runtime_id,
      surface_key: surface.surface_key,
      tmux_session: surface.tmux_session,
      snapshot_mode: false,
      interaction_mode: "iframe",
      server_active: true,
      server_status: surface_server_status(surface, params),
      pane_registered: pane_id != nil,
      operator_visible: operator_visible,
      browser_loaded: visibility.browser_loaded,
      browser_loaded_at: visibility.browser_loaded_at,
      operator_visible_state: visibility.operator_visible_state,
      visibility: visibility,
      active: operator_visible,
      pane_id: pane_id
    }
  end

  defp surface_visibility(nil), do: preview_visibility_from_activity([])

  defp surface_visibility(%{} = registration) do
    registration.workspace_id
    |> PreviewActivity.recent_pane(registration.pane_id, 20)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> preview_visibility_from_activity()
  end

  defp surface_server_status(%Surface{} = surface, params) do
    scoped_session = string_param(params, :tmux_session)
    session_match? = is_nil(scoped_session) or surface.tmux_session in [nil, scoped_session]

    status =
      cond do
        is_binary(scoped_session) and not session_match? -> "wrong_tmux_session"
        surface.source == :runtime -> "runtime_recorded"
        surface.source == :terminal -> "terminal_detected"
        surface.source == :manager -> "manager_configured"
        true -> Atom.to_string(surface.source)
      end

    %{
      status: status,
      port: surface.port,
      source: Atom.to_string(surface.source),
      tmux_session: surface.tmux_session,
      scoped_tmux_session: scoped_session,
      session_match: session_match?,
      runtime_id: surface.runtime_id
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  @doc "List discoverable surfaces for agent planning."
  def list_surfaces(workspace),
    do: Previews.discover_surfaces(WorkspaceContext.prepare(workspace))
end
