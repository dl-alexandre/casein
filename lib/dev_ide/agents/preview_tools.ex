defmodule DevIDE.Agents.PreviewTools do
  @moduledoc """
  Narrow agent-facing preview operations.

  Agents can open workspace surfaces, observe pages, interact with trusted
  previews, and capture evidence — without arbitrary browser or external URL
  access.
  """

  alias DevIDE.PreviewActivity
  alias DevIDE.Agents.BrowserControl
  alias DevIDE.PreviewControl
  alias DevIDE.PreviewPanes
  alias DevIDE.Previews
  alias DevIDE.Previews.{Surface, SurfaceResolver, Url, WorkspaceContext}
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
    open_props = Params.preview_open_props()
    session_only = Tool.object(%{session_id: Params.session_id()}, [:session_id])

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
          "Call before preview_open_app to pick a surface name.",
        Tool.object(workspace_props, [:workspace_id])
      ),
      Tool.define(
        "preview_open_current_workspace",
        "Open the pre-scoped current workspace app preview, auto-navigate to the DevIDE " <>
          "workspace viewer on loopback when available, and return the control session. " <>
          "On loopback, returns navigated_to on success or navigation_failed when open " <>
          "succeeded but viewer navigation was blocked. " <>
          "Prefer this when the MCP endpoint initialize response says it is pre-scoped.",
        Tool.object(Map.drop(open_props, [:workspace_id, :workspace_path]))
      ),
      Tool.define(
        "preview_open_app",
        "Open the workspace app preview surface in a controllable session. On loopback " <>
          "DevIDE (app-local), auto-navigates to the workspace viewer route and returns " <>
          "navigated_to on success or navigation_failed when open succeeded but viewer " <>
          "navigation was blocked.",
        Tool.object(open_props, [:workspace_id])
      ),
      Tool.define(
        "preview_open_localhost",
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
        "Click an element by CSS selector or viewport coordinates.",
        Tool.object(
          %{
            session_id: Params.session_id(),
            selector: Params.selector(),
            x: Params.x(),
            y: Params.y()
          },
          [:session_id]
        )
      ),
      Tool.define(
        "preview_type",
        "Type text into an input matched by CSS selector.",
        Tool.object(
          %{
            session_id: Params.session_id(),
            selector: Params.selector(),
            text: Params.text()
          },
          [:session_id, :selector, :text]
        )
      ),
      Tool.define(
        "preview_press",
        "Press a keyboard key in the preview session.",
        Tool.object(%{session_id: Params.session_id(), key: Params.key()}, [:session_id, :key])
      ),
      Tool.define(
        "preview_screenshot",
        "Capture a screenshot artifact from the current preview page.",
        session_only
      ),
      Tool.define(
        "preview_close",
        "Close a preview control session and release browser resources.",
        session_only
      ),
      Tool.define(
        "preview_get_storage",
        "Return localStorage and sessionStorage for the current preview origin.",
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
      "preview_surfaces" -> surfaces(workspace)
      "preview_open_current_workspace" -> open_app_preview(workspace, params)
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
      "preview_report_errors" -> report_errors(params)
      "preview_reload_iframe" -> reload_iframe(workspace, params)
      "devide_reload_page" -> reload_page(workspace, params)
      _ -> {:error, :unknown_tool}
    end
  end

  @doc "List discoverable preview surfaces for agent planning."
  @spec surfaces(map()) :: {:ok, map()} | {:error, term()}
  def surfaces(workspace) when is_map(workspace) do
    workspace = WorkspaceContext.prepare(workspace)

    payload =
      workspace
      |> Previews.discover_surfaces()
      |> Enum.map(&surface_payload/1)

    {:ok, %{surfaces: payload}}
  end

  @doc "Open the app (or named) preview surface for agent feedback."
  @spec open_app_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_app_preview(workspace, params \\ %{}) do
    surface = Map.get(params, "surface", Map.get(params, :surface, "app"))

    with {:ok, url} <- surface_url(workspace, surface),
         opts <- split_opts(params, workspace),
         {:ok, result} <- split_preview_pane(workspace, url, opts),
         {:ok, navigation} <- maybe_navigate_to_workspace(workspace, result.session) do
      {:ok, session_payload(result.session, navigation) |> Map.put(:pane_id, result.pane_id)}
    end
  end

  @doc "Open a localhost preview on an allowed port."
  @spec open_localhost_preview(map(), map()) :: {:ok, map()} | {:error, term()}
  def open_localhost_preview(workspace, params \\ %{}) when is_map(workspace) do
    with {:ok, port} <- parse_port(Map.get(params, "port") || Map.get(params, :port)),
         :ok <- WorkspaceContext.validate_port(WorkspaceContext.prepare(workspace), port),
         path <- localhost_path(workspace, port, params),
         url = WorkspaceContext.localhost_url(port, path),
         opts <- split_opts(params, workspace),
         {:ok, result} <- split_preview_pane(workspace, url, opts) do
      {:ok, session_payload(result.session) |> Map.put(:pane_id, result.pane_id)}
    end
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
         {:ok, split_target_pane_id} <- split_target_pane_id(tmux_session),
         command <- preview_command(url, opts),
         {:ok, pane_id} <-
           tmux_adapter().split_pane(tmux_session, split_target_pane_id, "h",
             cwd: Keyword.get(opts, :cwd) || workspace_host_path(workspace),
             command: command
           ),
         # tmux focuses the new preview holder; restore the operator pane so
         # Ghostty keeps streaming shell output instead of devide-preview text.
         :ok <- tmux_adapter().select_pane(tmux_session, split_target_pane_id),
         {:ok, registration} <- await_pane_registration(pane_id, workspace, url, opts) do
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
      latest_activity = PreviewActivity.latest_pane(registration.workspace_id, pane_id)

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

      {:ok,
       %{
         pane_id: pane_id,
         workspace_id: registration.workspace_id,
         preview_id: registration.preview_id,
         session_id: session_id,
         url: registration.url,
         display_url: registration.display_url,
         title: preview_title(registration, latest_observation),
         mode: preview_mode(registration),
         status: preview_status(registration),
         snapshot_mode: preview_mode(registration) == "snapshot",
         latest_screenshot: observation_payload(latest_screenshot),
         latest_observation: observation_payload(latest_observation),
         last_interaction: activity_payload(latest_activity),
         recent_activity:
           registration.workspace_id
           |> PreviewActivity.recent_pane(pane_id, limit)
           |> Enum.map(&activity_payload/1)
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
            %{selector: selector}

          x = Map.get(params, "x") || Map.get(params, :x) ->
            y = Map.get(params, "y") || Map.get(params, :y)
            %{x: x, y: y}

          true ->
            %{}
        end

      with {:ok, observation} <- PreviewControl.click(id, target) do
        {:ok, maybe_sync_pane_navigation(id, observation)}
      end
    end
  end

  @doc "Type into a preview input."
  @spec type(map()) :: {:ok, map()} | {:error, term()}
  def type(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      selector = Map.get(params, "selector") || Map.get(params, :selector)
      text = Map.get(params, "text") || Map.get(params, :text)

      with {:ok, observation} <- PreviewControl.type(id, selector, text) do
        {:ok, maybe_sync_pane_navigation(id, observation)}
      end
    end
  end

  @doc "Press a key in the preview session."
  @spec press(map()) :: {:ok, map()} | {:error, term()}
  def press(params) when is_map(params) do
    with {:ok, id} <- parse_id(Map.get(params, "session_id") || Map.get(params, :session_id)) do
      key = Map.get(params, "key") || Map.get(params, :key)

      with {:ok, observation} <- PreviewControl.press(id, key) do
        {:ok, maybe_sync_pane_navigation(id, observation)}
      end
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

  def close(id) when is_integer(id), do: do_close(id)

  @doc "Return preview origin localStorage and sessionStorage."
  @spec get_storage(map() | integer()) :: {:ok, map()} | {:error, term()}
  def get_storage(%{"session_id" => id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(%{session_id: id}),
    do: with({:ok, id} <- parse_id(id), do: PreviewControl.get_storage(id))

  def get_storage(id) when is_integer(id), do: PreviewControl.get_storage(id)

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

  defp surface_url(workspace, surface) do
    case SurfaceResolver.get(WorkspaceContext.prepare(workspace), surface) do
      %Surface{url: url} when is_binary(url) -> {:ok, url}
      _ -> {:error, :surface_not_found}
    end
  end

  defp maybe_kill_preview_pane(session_id) do
    case PreviewPanes.get_by_session(session_id) do
      %{pane_id: pane_id, tmux_session: tmux_session}
      when is_binary(tmux_session) and is_binary(pane_id) ->
        _ = tmux_adapter().kill_pane(tmux_session, pane_id)
        _ = PreviewPanes.deregister(pane_id)
        :ok

      _ ->
        :ok
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
        PreviewPanes.register(%{
          "pane_id" => pane_id,
          "url" => url,
          "workspace" => workspace,
          "workspace_id" => workspace_id(workspace),
          "cwd" => Keyword.get(opts, :cwd) || workspace_host_path(workspace),
          "viewport" => viewport_string(Keyword.get(opts, :viewport)),
          "tmux_session" => Keyword.get(opts, :tmux_session) || workspace_tmux_session(workspace),
          "actor_id" => Keyword.get(opts, :actor_id)
        })
    end
  end

  defp split_target_pane_id(tmux_session) do
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
    |> Kernel.++([preview_cli_executable(), shell_quote(url)])
    |> maybe_add_viewport_arg(viewport)
    |> Enum.join(" ")
  end

  defp maybe_add_preview_env(parts, _key, nil), do: parts
  defp maybe_add_preview_env(parts, _key, ""), do: parts
  defp maybe_add_preview_env(parts, key, value), do: parts ++ ["#{key}=#{shell_quote(value)}"]

  defp maybe_add_viewport_arg(parts, nil), do: parts
  defp maybe_add_viewport_arg(parts, ""), do: parts

  defp maybe_add_viewport_arg(parts, viewport),
    do: parts ++ ["--viewport", shell_quote(viewport)]

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
    tmux_session = resolve_tmux_session(workspace, Map.new(params))

    tool_opts(params, workspace)
    |> Keyword.merge(
      tmux_session: tmux_session,
      workspace_id: workspace_id(workspace),
      cwd: Map.get(params, "cwd") || Map.get(params, :cwd) || workspace_host_path(workspace),
      viewport: Map.get(params, "viewport") || Map.get(params, :viewport)
    )
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
  end

  defp workspace_tmux_session(workspace) do
    workspace
    |> workspace_matching_sessions()
    |> pick_workspace_session()
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

  defp workspace_id(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

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
      default_headers: default_headers(params, workspace),
      new_control_session: boolean_param(params, :new_control_session),
      isolation_key: string_param(params, :isolation_key)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
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

  defp parse_port(port) when is_integer(port), do: {:ok, port}

  defp parse_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_port}
    end
  end

  defp parse_port(_), do: {:error, :invalid_port}

  defp surface_payload(%Surface{} = surface) do
    %{
      name: surface.name,
      url: surface.url,
      title: surface.title,
      port: surface.port,
      source: Atom.to_string(surface.source),
      snapshot_mode: false,
      interaction_mode: "iframe"
    }
  end

  @doc "List discoverable surfaces for agent planning."
  def list_surfaces(workspace),
    do: Previews.discover_surfaces(WorkspaceContext.prepare(workspace))
end
