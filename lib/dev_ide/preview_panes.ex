defmodule DevIDE.PreviewPanes do
  @moduledoc """
  Registry of preview panes bound to tmux pane ids.

  Registers via the `devide-preview` CLI or direct API calls, creates
  `Preview` + `ControlSession` records through `PreviewControl`, persists the
  pane binding for refresh/restart recovery, subscribes to tmux topology
  updates to expire vanished panes, and broadcasts pane lifecycle on the
  workspace preview PubSub topic.
  """

  use GenServer

  import Ecto.Query

  alias DevIDE.Audit
  alias DevIDE.PreviewActivity
  alias DevIDE.PreviewControl
  alias DevIDE.Previews
  alias DevIDE.Previews.{ControlSession, Preview, PreviewPaneRegistration}
  alias DevIDE.Previews.Url
  alias DevIDE.Previews.WorkspaceContext
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases
  alias DevIde.Repo

  @table :dev_ide_preview_panes
  @topology_tag DevIDE.Terminals.TmuxTopology

  @type registration :: %{
          id: String.t(),
          pane_id: String.t(),
          preview_id: integer(),
          control_session_id: integer(),
          url: String.t(),
          display_url: String.t(),
          source_url: String.t() | nil,
          viewport: map() | nil,
          workspace_id: String.t(),
          tmux_session: String.t() | nil,
          shared: boolean(),
          source_pane_id: String.t() | nil,
          placement: String.t() | nil,
          anchor_pane_id: String.t() | nil,
          anchor_window_id: String.t() | nil,
          pane_window_id: String.t() | nil
        }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec register(map()) :: {:ok, registration()} | {:error, term()}
  def register(attrs) when is_map(attrs) do
    GenServer.call(__MODULE__, {:register, attrs})
  end

  @spec deregister(String.t()) :: :ok | {:error, :not_found}
  def deregister(pane_id) when is_binary(pane_id) do
    GenServer.call(__MODULE__, {:deregister, pane_id})
  end

  @spec navigate(String.t(), String.t()) :: {:ok, registration()} | {:error, term()}
  def navigate(pane_id, path_or_url) when is_binary(pane_id) and is_binary(path_or_url) do
    GenServer.call(__MODULE__, {:navigate, pane_id, path_or_url})
  end

  @spec go_back(String.t()) :: {:ok, registration() | :unchanged} | {:error, term()}
  def go_back(pane_id) when is_binary(pane_id) do
    GenServer.call(__MODULE__, {:history_action, pane_id, :go_back})
  end

  @spec go_forward(String.t()) :: {:ok, registration() | :unchanged} | {:error, term()}
  def go_forward(pane_id) when is_binary(pane_id) do
    GenServer.call(__MODULE__, {:history_action, pane_id, :go_forward})
  end

  @spec reload(String.t()) :: {:ok, registration() | :unchanged} | {:error, term()}
  def reload(pane_id) when is_binary(pane_id) do
    GenServer.call(__MODULE__, {:history_action, pane_id, :reload})
  end

  @spec sync_control_navigation(integer(), String.t()) ::
          {:ok, registration() | :unchanged} | {:error, term()}
  def sync_control_navigation(session_id, current_url)
      when is_integer(session_id) and is_binary(current_url) do
    GenServer.call(__MODULE__, {:sync_control_navigation, session_id, current_url})
  end

  @spec show_artifact(integer(), String.t()) :: {:ok, registration()} | {:error, term()}
  def show_artifact(session_id, artifact_path)
      when is_integer(session_id) and is_binary(artifact_path) do
    GenServer.call(__MODULE__, {:show_artifact, session_id, artifact_path})
  end

  @spec click_snapshot(String.t(), map()) ::
          {:ok, registration()} | {:error, term()}
  def click_snapshot(pane_id, coords) when is_binary(pane_id) and is_map(coords) do
    with %{control_session_id: session_id} = registration <- get_by_pane(pane_id),
         :ok <- ensure_snapshot_registration(registration),
         {:ok, target} <- snapshot_click_target(registration, coords),
         {:ok, _observation} <- PreviewControl.click(session_id, target),
         {:ok, screenshot} <- PreviewControl.screenshot(session_id),
         artifact_path when is_binary(artifact_path) <-
           Map.get(screenshot, :artifact_path) || Map.get(screenshot, "artifact_path") do
      show_artifact(session_id, artifact_path)
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :missing_screenshot_artifact}
    end
  end

  @spec get_by_pane(String.t()) :: registration() | nil
  def get_by_pane(pane_id) when is_binary(pane_id) do
    case lookup_by_pane(pane_id) do
      nil ->
        if Process.whereis(__MODULE__) == self() do
          nil
        else
          GenServer.call(__MODULE__, {:get_by_pane, pane_id})
        end

      registration ->
        registration
    end
  end

  @spec get_by_session(integer()) :: registration() | nil
  def get_by_session(session_id) when is_integer(session_id) do
    GenServer.call(__MODULE__, {:get_by_session, session_id})
  end

  @spec list_for_workspace(String.t()) :: [registration()]
  def list_for_workspace(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list_for_workspace, WorkspaceAliases.viewer_ids(workspace_id)})
  end

  @doc """
  Returns registrations stored directly under `workspace_id`, without resolving
  folder/manager aliases.

  Use this for read-only cross-workspace summaries where a manager status fetch
  would be surprising. Viewer-facing broadcasts should keep using
  `list_for_workspace/1` so linked workspace ids share preview state.
  """
  @spec list_for_workspace_exact(String.t()) :: [registration()]
  def list_for_workspace_exact(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:list_for_workspace, [workspace_id]})
  end

  @spec list_for_workspace_map(String.t()) :: %{String.t() => registration()}
  def list_for_workspace_map(workspace_id) when is_binary(workspace_id) do
    workspace_id
    |> list_for_workspace()
    |> Map.new(&{&1.pane_id, &1})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :set, :protected])
    {:ok, %{subscriptions: MapSet.new(), workspace_index: %{}}}
  end

  @impl true
  def handle_call({:register, attrs}, _from, state) do
    case do_register(attrs, state) do
      {:ok, registration, state} -> {:reply, {:ok, registration}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:deregister, pane_id}, _from, state) do
    case do_deregister(pane_id, state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:navigate, pane_id, path_or_url}, _from, state) do
    case do_navigate(pane_id, path_or_url) do
      {:ok, registration} -> {:reply, {:ok, registration}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:history_action, pane_id, action}, _from, state) do
    case do_history_action(pane_id, action) do
      {:ok, registration} -> {:reply, {:ok, registration}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sync_control_navigation, session_id, current_url}, _from, state) do
    {registration, state} =
      case lookup_by_session(state.workspace_index, session_id) do
        nil -> get_or_rehydrate_by_session(session_id, state)
        registration -> {registration, state}
      end

    case registration do
      nil ->
        {:reply, {:ok, :unchanged}, state}

      registration ->
        case do_sync_control_navigation(registration, current_url) do
          {:ok, registration} -> {:reply, {:ok, registration}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:show_artifact, session_id, artifact_path}, _from, state) do
    {registration, state} =
      case lookup_by_session(state.workspace_index, session_id) do
        nil -> get_or_rehydrate_by_session(session_id, state)
        registration -> {registration, state}
      end

    case registration do
      nil ->
        {:reply, {:error, :not_found}, state}

      registration ->
        # Re-snapshotting the current page (e.g. snapshot click): keep whatever
        # real source URL we already resolved for it.
        case do_show_artifact(registration, artifact_path, Map.get(registration, :source_url)) do
          {:ok, registration} -> {:reply, {:ok, registration}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:get_by_session, session_id}, _from, state) do
    case lookup_by_session(state.workspace_index, session_id) do
      nil ->
        {registration, state} = get_or_rehydrate_by_session(session_id, state)
        {:reply, registration, state}

      registration ->
        {:reply, registration, state}
    end
  end

  def handle_call({:get_by_pane, pane_id}, _from, state) do
    {registration, state} = get_or_rehydrate_by_pane(pane_id, state)
    {:reply, registration, state}
  end

  def handle_call({:list_for_workspace, workspace_ids}, _from, state) do
    state = rehydrate_workspaces(workspace_ids, state)
    {:reply, list_workspace_registrations(state.workspace_index, workspace_ids), state}
  end

  def handle_call(:clear, _from, _state) do
    close_all_persisted_registrations()
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{subscriptions: MapSet.new(), workspace_index: %{}}}
  end

  @impl true
  def handle_info({@topology_tag, {:updated, topology}}, state) do
    {:noreply, expire_vanished_panes(topology, state)}
  end

  def handle_info({@topology_tag, {:session_terminated, %{session: session}}}, state) do
    pane_ids =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(fn pane_id ->
        case get_by_pane(pane_id) do
          %{tmux_session: ^session} -> true
          _ -> false
        end
      end)

    state =
      Enum.reduce(pane_ids, state, fn pane_id, acc ->
        case do_deregister(pane_id, acc) do
          {:ok, next} -> next
          {:error, _, next} -> next
        end
      end)

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp do_register(attrs, state) do
    pane_id = string_param(attrs, "pane_id") || string_param(attrs, :pane_id)

    if existing = get_by_pane(pane_id) do
      if truthy_param(attrs, "heartbeat") || truthy_param(attrs, :heartbeat) do
        broadcast_registered(existing)
        refresh_topology(existing.tmux_session)
        {:ok, existing, state}
      else
        register_fresh(attrs, pane_id, state)
      end
    else
      register_fresh(attrs, pane_id, state)
    end
  end

  defp register_fresh(attrs, pane_id, state) do
    state =
      if existing = lookup_by_pane(pane_id) do
        case do_deregister(existing.pane_id, state) do
          {:ok, next} -> next
          {:error, _, next} -> next
        end
      else
        close_persisted_registration_for_pane(pane_id)
        state
      end

    tmux_session = string_param(attrs, "tmux_session") || string_param(attrs, :tmux_session)

    with {:ok, pane_id} <- require_binary(pane_id, :missing_pane_id),
         {:ok, url} <- normalize_url(string_param(attrs, "url") || string_param(attrs, :url)),
         {:ok, workspace} <- resolve_workspace(attrs),
         :ok <- validate_trusted_url(workspace, url),
         viewport <-
           parse_viewport(string_param(attrs, "viewport") || string_param(attrs, :viewport)),
         {:ok, registration} <-
           build_registration(workspace, pane_id, url, viewport, tmux_session, attrs) do
      registration = %{
        registration
        | id: pane_id,
          pane_id: pane_id,
          viewport: viewport,
          tmux_session: tmux_session
      }

      with {:ok, _persisted} <- persist_registration(registration) do
        :ets.insert(@table, {pane_id, registration})

        state =
          state
          |> put_workspace_index(pane_id, workspace.id)
          |> maybe_subscribe_topology(tmux_session)

        broadcast_registered(registration)
        record_activity(registration, "registered", registration_summary(registration))
        refresh_topology(tmux_session)
        emit_audit!("preview_pane.registered", registration)

        {:ok, registration, state}
      end
    end
  end

  defp truthy_param(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) in [true, 1, "1", "true", "yes", "on"]
  end

  defp do_deregister(pane_id, state) do
    case get_by_pane(pane_id) do
      nil ->
        {:error, :not_found, state}

      registration ->
        :ets.delete(@table, pane_id)
        close_persisted_registration(registration)

        unless session_has_other_registrations?(registration.control_session_id) do
          _ = PreviewControl.close_session(registration.control_session_id)

          if preview =
               Previews.get_for_workspace(registration.preview_id, registration.workspace_id) do
            _ = Previews.close(preview)
          end
        end

        state = drop_workspace_index(state, pane_id, registration.workspace_id)
        broadcast_removed(registration)
        record_activity(registration, "removed", "preview pane removed")
        emit_audit!("preview_pane.removed", registration)
        {:ok, state}
    end
  end

  defp do_navigate(pane_id, path_or_url) do
    with %{display_url: display_url} = registration <- get_by_pane(pane_id),
         new_display_url <- Url.resolve_against(path_or_url, display_url),
         :ok <- require_trusted_preview_url(new_display_url),
         control_url <- control_url_for(new_display_url),
         {:ok, observation} <-
           PreviewControl.navigate(
             registration.control_session_id,
             control_url,
             control_activity_opts(registration)
           ) do
      if frame_blocked?(observation) do
        navigate_frame_blocked(registration, new_display_url)
      else
        maybe_proxy_for_hmr(registration, new_display_url)
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # A frame-blocked page can't embed live. When the reverse proxy is enabled
  # and the target is a loopback dev server, re-serve it through the proxy with
  # frame headers stripped so it stays interactive; otherwise fall back to a
  # screenshot. The proxied page is still scoped by the controller to loopback
  # ports authorized for this workspace.
  defp navigate_frame_blocked(registration, url) do
    case proxy_display_url(registration, url) do
      {:ok, proxy_url} ->
        persist_registration_url(registration, proxy_url, "preview_pane.proxied", source_url: url)

      :error ->
        navigate_as_snapshot(registration, url)
    end
  end

  defp proxy_display_url(registration, url) do
    with true <- preview_proxy_enabled?(),
         wsid when is_binary(wsid) <- registration.workspace_id,
         true <- Url.localhost_url?(url),
         %URI{port: port} = uri when is_integer(port) and port > 0 <- URI.parse(url) do
      path = uri.path || "/"
      query = if uri.query, do: "?" <> uri.query, else: ""
      {:ok, "/preview-proxy/#{wsid}/#{port}#{path}#{query}"}
    else
      _ -> :error
    end
  end

  defp preview_proxy_enabled? do
    case Application.get_env(:dev_ide, :preview_proxy_enabled) do
      nil -> System.get_env("DEV_IDE_PREVIEW_PROXY", "true") not in ~w(0 false no)
      val -> !!val
    end
  end

  # When the HMR tunnel is enabled, route a loopback preview through the proxy
  # even if it isn't frame-blocked, so the import map + WebSocket shim + tunnel
  # engage for dev servers (Vite/webpack/LiveReload). The initial-show and
  # control-sync paths already proxy loopback URLs; this keeps in-pane navigation
  # consistent. No-op (direct embed) when HMR is disabled or the URL isn't a
  # proxyable loopback target.
  defp maybe_proxy_for_hmr(registration, url) do
    with true <- hmr_tunnel_enabled?(),
         {:ok, proxy_url} <- proxy_display_url(registration, url) do
      persist_registration_url(registration, proxy_url, "preview_pane.proxied", source_url: url)
    else
      _ -> persist_registration_url(registration, url, "preview_pane.navigated")
    end
  end

  defp hmr_tunnel_enabled? do
    :dev_ide
    |> Application.get_env(:preview_proxy_hmr, [])
    |> Keyword.get(:enabled, false)
  end

  # Some sites refuse iframe embedding (X-Frame-Options / CSP frame-ancestors),
  # so a live navigation would leave a blank pane. Capture a screenshot and show
  # that instead. If the capture fails, fall back to the live URL so the
  # destination is still recorded rather than erroring outright.
  defp navigate_as_snapshot(registration, attempted_url) do
    with {:ok, %{artifact_path: artifact_path}} when is_binary(artifact_path) <-
           PreviewControl.screenshot(
             registration.control_session_id,
             control_activity_opts(registration)
           ),
         {:ok, registration} <- do_show_artifact(registration, artifact_path, attempted_url) do
      {:ok, registration}
    else
      _ -> persist_registration_url(registration, attempted_url, "preview_pane.navigated")
    end
  end

  defp frame_blocked?(observation) when is_map(observation) do
    Map.get(observation, :frame_blocked) == true or Map.get(observation, "frame_blocked") == true
  end

  defp frame_blocked?(_), do: false

  defp do_history_action(pane_id, action) when action in [:go_back, :go_forward, :reload] do
    with %{control_session_id: session_id} = registration <- get_by_pane(pane_id),
         {:ok, observation} <-
           apply(PreviewControl, action, [session_id, control_activity_opts(registration)]) do
      case observation_url(observation) do
        url when is_binary(url) and url != "" ->
          case do_sync_control_navigation(registration, url) do
            {:ok, :unchanged} ->
              broadcast_registered(registration)
              {:ok, registration}

            {:error, :untrusted_preview_url} ->
              with {:ok, %{artifact_path: artifact_path}} <-
                     PreviewControl.screenshot(session_id, control_activity_opts(registration)) do
                do_show_artifact(registration, artifact_path, url)
              end

            other ->
              other
          end

        _ ->
          broadcast_registered(registration)
          {:ok, registration}
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_sync_control_navigation(registration, current_url) do
    new_display_url = display_url_for_control_url(registration, current_url)

    cond do
      new_display_url == registration.display_url ->
        {:ok, :unchanged}

      not embeddable_display_url?(registration, new_display_url) ->
        {:error, :untrusted_preview_url}

      session_registrations_unchanged?(registration.control_session_id, new_display_url) ->
        {:ok, :unchanged}

      true ->
        persist_registration_url(registration, new_display_url, "preview_pane.control_navigated")
    end
  end

  defp do_show_artifact(registration, artifact_path, source_url) do
    with {:ok, display_url} <- artifact_display_url(registration, artifact_path) do
      persist_registration_url(registration, display_url, "preview_pane.snapshot_shown",
        source_url: source_url
      )
    end
  end

  defp control_activity_opts(registration) do
    [
      pane_id: registration.pane_id,
      preview_id: registration.preview_id,
      workspace_id: registration.workspace_id
    ]
  end

  defp observation_url(%{url: url}) when is_binary(url), do: url
  defp observation_url(%{"url" => url}) when is_binary(url), do: url
  defp observation_url(_), do: nil

  defp persist_registration_url(registration, display_url, audit_action, opts \\ []) do
    source_url = normalize_source_url(Keyword.get(opts, :source_url), display_url)

    registrations = registrations_by_session(registration.control_session_id)

    with :ok <-
           update_preview_url(
             registration.preview_id,
             registration.workspace_id,
             display_url,
             source_url
           ) do
      updated =
        Enum.map(registrations, fn reg ->
          updated =
            %{reg | url: display_url, display_url: display_url}
            |> Map.put(:source_url, source_url)

          {:ok, _persisted} = persist_registration(updated)

          :ets.insert(@table, {updated.pane_id, updated})
          broadcast_registered(updated)
          record_activity(updated, activity_event(audit_action), activity_summary(audit_action))
          emit_audit!(audit_action, updated)
          updated
        end)

      updated
      |> Enum.map(& &1.tmux_session)
      |> Enum.uniq()
      |> Enum.each(&refresh_topology/1)

      {:ok, Enum.find(updated, &(&1.pane_id == registration.pane_id)) || List.first(updated)}
    end
  end

  # A source URL is only meaningful while it differs from the URL we display
  # (i.e. a snapshot/served capture standing in for a real site). When they
  # match, the displayed URL is already real, so drop it to avoid stale data.
  defp normalize_source_url(source_url, display_url)
       when is_binary(source_url) and source_url != "" and source_url != display_url,
       do: source_url

  defp normalize_source_url(_source_url, _display_url), do: nil

  defp update_preview_url(preview_id, workspace_id, display_url, source_url) do
    case Previews.update_url(preview_id, workspace_id, display_url, source_url: source_url) do
      {:ok, _preview} -> :ok
      {:error, reason} -> {:error, reason}
      nil -> {:error, :preview_not_found}
    end
  end

  defp display_url_for_control_url(registration, current_url) do
    control_origin = Url.origin_of(control_url_for(registration.display_url))
    current_origin = Url.origin_of(current_url)

    cond do
      devide_loopback_url?(URI.parse(current_url)) ->
        browser_display_url(current_url)

      Url.localhost_url?(current_url) ->
        case proxy_display_url(registration, current_url) do
          {:ok, proxy_url} -> proxy_url
          :error -> current_url
        end

      is_binary(control_origin) and current_origin == control_origin ->
        replace_origin(current_url, registration.display_url)

      true ->
        current_url
    end
  end

  defp replace_origin(url, origin_url) do
    source = URI.parse(url)
    origin = URI.parse(origin_url)

    %URI{
      source
      | scheme: origin.scheme,
        host: origin.host,
        port: origin.port
    }
    |> URI.to_string()
  end

  defp artifact_display_url(registration, "/preview-artifacts/" <> _ = path) do
    case artifact_origin(registration) do
      origin when is_binary(origin) -> {:ok, origin <> path <> "?fit=" <> artifact_fit(path)}
      _ -> {:error, :missing_artifact_origin}
    end
  end

  defp artifact_display_url(_registration, _), do: {:error, :invalid_artifact_path}

  # Recordings render in a <video> wrapper; snapshots in an <img> wrapper.
  defp artifact_fit(path) do
    case path |> URI.parse() |> Map.get(:path, path) |> Path.extname() |> String.downcase() do
      ".webm" -> "playback"
      ".mp4" -> "playback"
      _ -> "preview"
    end
  end

  defp artifact_origin(registration) do
    app_url = Application.get_env(:dev_ide, :preview_app_url)

    cond do
      is_binary(app_url) and app_url != "" ->
        Url.origin_of(app_url)

      is_binary(registration.display_url) ->
        Url.origin_of(registration.display_url)

      true ->
        nil
    end
  end

  defp ensure_snapshot_registration(%{display_url: display_url}) when is_binary(display_url) do
    if String.contains?(display_url, "/preview-artifacts/") do
      :ok
    else
      {:error, :not_snapshot_preview}
    end
  end

  defp ensure_snapshot_registration(_), do: {:error, :not_snapshot_preview}

  defp snapshot_click_target(registration, coords) do
    with {:ok, x} <- integer_coord(coords, "x"),
         {:ok, y} <- integer_coord(coords, "y"),
         :ok <- ensure_inside_viewport(registration.viewport, x, y) do
      {:ok, %{x: x, y: y}}
    end
  end

  defp integer_coord(coords, key) do
    value =
      case key do
        "x" -> Map.get(coords, "x") || Map.get(coords, :x)
        "y" -> Map.get(coords, "y") || Map.get(coords, :y)
      end

    cond do
      is_integer(value) -> {:ok, value}
      is_float(value) -> {:ok, round(value)}
      is_binary(value) -> parse_integer_coord(value)
      true -> {:error, :invalid_snapshot_click}
    end
  end

  defp parse_integer_coord(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, int}
      _ -> {:error, :invalid_snapshot_click}
    end
  end

  defp ensure_inside_viewport(%{width: width, height: height}, x, y)
       when is_integer(width) and is_integer(height) do
    if x >= 0 and y >= 0 and x < width and y < height do
      :ok
    else
      {:error, :snapshot_click_out_of_bounds}
    end
  end

  defp ensure_inside_viewport(%{"width" => width, "height" => height}, x, y)
       when is_integer(width) and is_integer(height),
       do: ensure_inside_viewport(%{width: width, height: height}, x, y)

  defp ensure_inside_viewport(_viewport, _x, _y), do: :ok

  defp embeddable_display_url?(registration, url) do
    if same_origin_path?(url) do
      true
    else
      origin = Url.origin_of(url)
      is_binary(origin) and origin in preview_allowed_origins(registration)
    end
  end

  defp same_origin_path?(url) when is_binary(url), do: String.starts_with?(url, "/")
  defp same_origin_path?(_), do: false

  defp preview_allowed_origins(registration) do
    preview =
      Previews.get_for_workspace(registration.preview_id, registration.workspace_id)

    allowed =
      case preview do
        %{metadata: %{"allowed_origins" => origins}} when is_list(origins) -> origins
        %{metadata: %{allowed_origins: origins}} when is_list(origins) -> origins
        _ -> Url.allowed_origins(nil)
      end

    allowed
    |> Enum.map(&Url.origin_of/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp open_preview(workspace, url, pane_id, attrs) do
    workspace = WorkspaceContext.prepare(workspace)
    close_existing_preview_for_pane(workspace, pane_id)

    control_url = control_url_for(url)
    display_url = browser_display_url(workspace, url)

    Previews.find_or_open(workspace, %{
      url: url,
      title: preview_title(url),
      mode: :tab,
      actor_id: string_param(attrs, "actor_id") || string_param(attrs, :actor_id),
      pane_id: pane_id,
      metadata: %{
        "surface" => "preview-pane",
        # Dedup identity is the tmux pane, not the generic "preview-pane" label
        # or the URL. This keeps each pane its own preview so two panes can show
        # the same URL at different viewports (mobile + desktop), while
        # re-registering the same pane at a new URL reuses and re-navigates.
        "surface_key" => "preview-pane:" <> pane_id,
        "surface_source" => "preview_pane",
        "control_url" => control_url,
        "display_url" => display_url,
        "allowed_origins" => allowed_origins(workspace, control_url)
      }
    })
  end

  defp build_registration(workspace, pane_id, url, viewport, tmux_session, attrs) do
    if truthy_param?(attrs, "share_session") || truthy_param?(attrs, :share_session) do
      build_shared_registration(workspace, pane_id, url, viewport, tmux_session, attrs)
    else
      build_owned_registration(workspace, pane_id, url, viewport, tmux_session, attrs)
    end
  end

  defp build_owned_registration(workspace, pane_id, url, viewport, tmux_session, attrs) do
    with {:ok, preview} <- open_preview(workspace, url, pane_id, attrs),
         {:ok, session} <-
           PreviewControl.open_for_preview(workspace, preview,
             actor_id: string_param(attrs, "actor_id") || string_param(attrs, :actor_id),
             control_url: preview.metadata["control_url"] || url,
             default_headers: pane_default_headers(workspace, attrs),
             storage_profile:
               string_param(attrs, "storage_profile") || string_param(attrs, :storage_profile),
             storage_profile_name:
               string_param(attrs, "storage_profile_name") ||
                 string_param(attrs, :storage_profile_name)
           ) do
      display_url =
        session.metadata["display_url"] || preview.metadata["display_url"] || preview.url

      {:ok,
       %{
         id: pane_id,
         pane_id: pane_id,
         preview_id: preview.id,
         control_session_id: session.id,
         url: url,
         display_url: display_url,
         source_url: preview.metadata["source_url"],
         viewport: viewport,
         workspace_id: workspace.id,
         tmux_session: tmux_session,
         shared: false,
         source_pane_id: nil
       }}
      |> put_registration_placement(attrs)
    end
  end

  defp build_shared_registration(workspace, pane_id, url, viewport, tmux_session, attrs) do
    with {:ok, source} <- shared_source_registration(workspace, url, attrs),
         :ok <- ensure_shared_source_open(source),
         :ok <- ensure_shared_source_scope(workspace, source) do
      {:ok,
       %{
         id: pane_id,
         pane_id: pane_id,
         preview_id: source.preview_id,
         control_session_id: source.control_session_id,
         url: source.url,
         display_url: source.display_url,
         source_url: Map.get(source, :source_url),
         viewport: viewport,
         workspace_id: source.workspace_id,
         tmux_session: tmux_session,
         shared: true,
         source_pane_id: source.pane_id
       }}
      |> put_registration_placement(attrs)
    end
  end

  defp put_registration_placement({:ok, registration}, attrs) do
    {:ok,
     registration
     |> Map.put(:placement, string_param(attrs, "placement") || string_param(attrs, :placement))
     |> Map.put(
       :anchor_pane_id,
       string_param(attrs, "anchor_pane_id") || string_param(attrs, :anchor_pane_id)
     )
     |> Map.put(
       :anchor_window_id,
       string_param(attrs, "anchor_window_id") || string_param(attrs, :anchor_window_id)
     )
     |> Map.put(
       :pane_window_id,
       string_param(attrs, "pane_window_id") || string_param(attrs, :pane_window_id)
     )}
  end

  defp shared_source_registration(workspace, url, attrs) do
    case string_param(attrs, "attach_to_pane_id") || string_param(attrs, :attach_to_pane_id) do
      pane_id when is_binary(pane_id) ->
        case get_by_pane(pane_id) do
          nil -> {:error, :no_shared_preview_found}
          registration -> {:ok, registration}
        end

      _ ->
        case shared_source_by_origin(workspace, url) do
          nil -> {:error, :no_shared_preview_found}
          registration -> {:ok, registration}
        end
    end
  end

  defp shared_source_by_origin(workspace, url) do
    origin = Url.origin_of(browser_display_url(workspace, url)) || Url.origin_of(url)

    if is_binary(origin) do
      workspace.id
      |> workspace_registrations_direct()
      |> Enum.find(fn registration ->
        Url.origin_of(registration.display_url) == origin ||
          Url.origin_of(registration.url) == origin
      end)
    end
  end

  defp ensure_shared_source_scope(workspace, %{workspace_id: workspace_id}) do
    if workspace_id in WorkspaceAliases.viewer_ids(workspace.id) do
      :ok
    else
      {:error, :no_shared_preview_found}
    end
  end

  defp ensure_shared_source_open(%{control_session_id: session_id, preview_id: preview_id}) do
    case PreviewControl.get_open_session_for_preview(session_id, preview_id) do
      nil -> {:error, :no_shared_preview_found}
      _ -> :ok
    end
  end

  defp registration_summary(%{shared: true}), do: "preview pane attached"
  defp registration_summary(_), do: "preview pane registered"

  def browser_display_url(url) when is_binary(url) do
    with %URI{path: path, query: query, fragment: fragment} = uri <- URI.parse(url),
         true <- devide_loopback_url?(uri) do
      %URI{path: path || "/", query: query, fragment: fragment}
      |> URI.to_string()
    else
      _ -> url
    end
  end

  def browser_display_url(url), do: url

  def browser_display_url(workspace, url) when is_map(workspace) and is_binary(url) do
    if devide_loopback_url?(URI.parse(url)) do
      browser_display_url(url)
    else
      case proxy_display_url(%{workspace_id: workspace_id(workspace)}, url) do
        {:ok, proxy_url} -> proxy_url
        :error -> browser_display_url(url)
      end
    end
  end

  def browser_display_url(_workspace, url), do: browser_display_url(url)

  defp workspace_id(workspace) when is_map(workspace) do
    Map.get(workspace, :id) || Map.get(workspace, "id")
  end

  defp close_existing_preview_for_pane(workspace, pane_id) do
    workspace_id = workspace.id || workspace[:id]

    preview =
      Previews.find_open_for_attrs(workspace_id, %{
        metadata: %{"surface_key" => "preview-pane:" <> pane_id}
      })

    if preview do
      _ = PreviewControl.close_sessions_for_preview(preview.id)
      _ = Previews.close(preview)
    end

    :ok
  end

  defp expire_vanished_panes(%{session: session, panes: panes}, state) do
    pane_ids = MapSet.new(Enum.map(panes || [], & &1.id))

    stale =
      state.workspace_index
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(fn pane_id ->
        case get_by_pane(pane_id) do
          %{tmux_session: ^session} = reg ->
            not MapSet.member?(pane_ids, reg.pane_id)

          _ ->
            false
        end
      end)
      |> Enum.reject(&pane_still_exists?(session, &1, pane_ids))

    Enum.reduce(stale, state, fn pane_id, acc ->
      case do_deregister(pane_id, acc) do
        {:ok, next} -> next
        {:error, _, next} -> next
      end
    end)
  end

  defp pane_still_exists?(session, pane_id, pane_ids) do
    MapSet.member?(pane_ids, pane_id) or
      session
      |> tmux_adapter().list_session_panes()
      |> Enum.any?(&(Map.get(&1, :id) == pane_id))
  end

  defp lookup_by_pane(pane_id) when is_binary(pane_id) do
    case :ets.lookup(@table, pane_id) do
      [{^pane_id, registration}] -> registration
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp get_or_rehydrate_by_pane(pane_id, state) do
    case lookup_by_pane(pane_id) do
      nil ->
        case load_open_persisted_registration(pane_id) do
          nil -> {nil, state}
          persisted -> rehydrate_persisted_registration(persisted, state)
        end

      registration ->
        {registration, state}
    end
  end

  defp get_or_rehydrate_by_session(session_id, state) when is_integer(session_id) do
    case load_open_persisted_registration_for_session(session_id) do
      nil -> {nil, state}
      persisted -> rehydrate_persisted_registration(persisted, state)
    end
  end

  defp rehydrate_workspaces(workspace_ids, state) when is_list(workspace_ids) do
    workspace_ids
    |> load_open_persisted_registrations()
    |> Enum.reduce(state, fn persisted, acc ->
      {_registration, next} = rehydrate_persisted_registration(persisted, acc)
      next
    end)
  end

  defp rehydrate_persisted_registration(%PreviewPaneRegistration{} = persisted, state) do
    registration = persisted_registration_to_map(persisted)

    cond do
      lookup_by_pane(registration.pane_id) ->
        {lookup_by_pane(registration.pane_id), state}

      not persisted_registration_live?(persisted) ->
        close_persisted_registration(registration)
        {nil, drop_workspace_index(state, registration.pane_id, registration.workspace_id)}

      true ->
        :ets.insert(@table, {registration.pane_id, registration})

        state =
          state
          |> put_workspace_index(registration.pane_id, registration.workspace_id)
          |> maybe_subscribe_topology(registration.tmux_session)

        {registration, state}
    end
  end

  defp persisted_registration_live?(%PreviewPaneRegistration{} = registration) do
    with %{status: :open} <- registration,
         %Preview{status: :open} <- registration.preview,
         %ControlSession{status: :open} <- registration.control_session,
         tmux_session when is_binary(tmux_session) and tmux_session != "" <-
           registration.tmux_session do
      tmux_session
      |> tmux_adapter().list_session_panes()
      |> Enum.any?(&(Map.get(&1, :id) == registration.pane_id))
    else
      _ -> false
    end
  end

  defp load_open_persisted_registration(pane_id) when is_binary(pane_id) do
    if preview_pane_persistence_enabled?() do
      Repo.one(
        from r in PreviewPaneRegistration,
          where: r.pane_id == ^pane_id and r.status == :open,
          preload: [:preview, :control_session],
          limit: 1
      )
    end
  end

  defp load_open_persisted_registration_for_session(session_id) when is_integer(session_id) do
    if preview_pane_persistence_enabled?() do
      Repo.one(
        from r in PreviewPaneRegistration,
          where: r.control_session_id == ^session_id and r.status == :open,
          preload: [:preview, :control_session],
          limit: 1
      )
    end
  end

  defp load_open_persisted_registrations(workspace_ids) when is_list(workspace_ids) do
    ids = Enum.reject(workspace_ids, &(&1 in [nil, ""]))

    if ids == [] or not preview_pane_persistence_enabled?() do
      []
    else
      Repo.all(
        from r in PreviewPaneRegistration,
          where: r.workspace_id in ^ids and r.status == :open,
          preload: [:preview, :control_session],
          order_by: [asc: r.inserted_at]
      )
    end
  end

  defp persist_registration(registration) when is_map(registration) do
    if preview_pane_persistence_enabled?() do
      do_persist_registration(registration)
    else
      {:ok, registration}
    end
  end

  defp do_persist_registration(registration) do
    attrs = %{
      workspace_id: registration.workspace_id,
      tmux_session: registration.tmux_session,
      pane_id: registration.pane_id,
      preview_id: registration.preview_id,
      control_session_id: registration.control_session_id,
      url: registration.url,
      display_url: registration.display_url,
      source_url: Map.get(registration, :source_url),
      viewport: registration.viewport,
      shared: Map.get(registration, :shared, false),
      source_pane_id: Map.get(registration, :source_pane_id),
      placement: Map.get(registration, :placement),
      anchor_pane_id: Map.get(registration, :anchor_pane_id),
      anchor_window_id: Map.get(registration, :anchor_window_id),
      pane_window_id: Map.get(registration, :pane_window_id),
      status: :open
    }

    case Repo.get_by(PreviewPaneRegistration, pane_id: registration.pane_id, status: :open) do
      %PreviewPaneRegistration{} = persisted ->
        persisted
        |> PreviewPaneRegistration.changeset(attrs)
        |> Repo.update()

      nil ->
        %PreviewPaneRegistration{}
        |> PreviewPaneRegistration.changeset(attrs)
        |> Repo.insert()
    end
  end

  defp close_persisted_registration(%{pane_id: pane_id}) when is_binary(pane_id) do
    close_persisted_registration_for_pane(pane_id)
  end

  defp close_persisted_registration(_registration), do: :ok

  defp close_persisted_registration_for_pane(pane_id)
       when is_binary(pane_id) and pane_id != "" do
    if preview_pane_persistence_enabled?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(r in PreviewPaneRegistration,
        where: r.pane_id == ^pane_id and r.status == :open
      )
      |> Repo.update_all(set: [status: :closed, updated_at: now])
    end

    :ok
  end

  defp close_persisted_registration_for_pane(_pane_id), do: :ok

  defp close_all_persisted_registrations do
    if preview_pane_persistence_enabled?() do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      from(r in PreviewPaneRegistration, where: r.status == :open)
      |> Repo.update_all(set: [status: :closed, updated_at: now])
    end

    :ok
  end

  defp preview_pane_persistence_enabled? do
    Application.get_env(:dev_ide, :preview_pane_persistence_enabled, true)
  end

  defp persisted_registration_to_map(%PreviewPaneRegistration{} = persisted) do
    %{
      id: persisted.pane_id,
      pane_id: persisted.pane_id,
      preview_id: persisted.preview_id,
      control_session_id: persisted.control_session_id,
      url: persisted.url,
      display_url: persisted.display_url,
      source_url: persisted.source_url,
      viewport: persisted.viewport,
      workspace_id: persisted.workspace_id,
      tmux_session: persisted.tmux_session,
      shared: persisted.shared,
      source_pane_id: persisted.source_pane_id,
      placement: persisted.placement,
      anchor_pane_id: persisted.anchor_pane_id,
      anchor_window_id: persisted.anchor_window_id,
      pane_window_id: persisted.pane_window_id
    }
  end

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, DevIDE.Terminals.Tmux)
  end

  defp maybe_subscribe_topology(state, tmux_session)
       when is_binary(tmux_session) and tmux_session != "" do
    if MapSet.member?(state.subscriptions, tmux_session) do
      state
    else
      _ = TmuxTopology.subscribe(tmux_session)
      %{state | subscriptions: MapSet.put(state.subscriptions, tmux_session)}
    end
  end

  defp maybe_subscribe_topology(state, _), do: state

  defp refresh_topology(tmux_session) when is_binary(tmux_session) and tmux_session != "" do
    _ = TmuxTopology.refresh(tmux_session)
    :ok
  end

  defp refresh_topology(_), do: :ok

  defp put_workspace_index(state, pane_id, workspace_id) do
    ids =
      state.workspace_index
      |> Map.get(workspace_id, [])
      |> then(&[pane_id | &1])
      |> Enum.uniq()

    %{state | workspace_index: Map.put(state.workspace_index, workspace_id, ids)}
  end

  defp drop_workspace_index(state, pane_id, workspace_id) do
    ids =
      state.workspace_index
      |> Map.get(workspace_id, [])
      |> Enum.reject(&(&1 == pane_id))

    workspace_index =
      if ids == [] do
        Map.delete(state.workspace_index, workspace_id)
      else
        Map.put(state.workspace_index, workspace_id, ids)
      end

    %{state | workspace_index: workspace_index}
  end

  defp list_workspace_registrations(workspace_index, workspace_ids) when is_list(workspace_ids) do
    workspace_ids
    |> Enum.flat_map(&Map.get(workspace_index, &1, []))
    |> Enum.uniq()
    |> Enum.map(&get_by_pane/1)
    |> Enum.reject(&is_nil/1)
  end

  defp lookup_by_session(workspace_index, session_id) do
    workspace_index
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(fn pane_id ->
      case get_by_pane(pane_id) do
        %{control_session_id: ^session_id} = reg -> reg
        _ -> nil
      end
    end)
  end

  defp registrations_by_session(session_id) when is_integer(session_id) do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_pane_id, registration} -> registration end)
    |> Enum.filter(&(&1.control_session_id == session_id))
  end

  defp workspace_registrations_direct(workspace_id) when is_binary(workspace_id) do
    workspace_ids = WorkspaceAliases.viewer_ids(workspace_id)

    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_pane_id, registration} -> registration end)
    |> Enum.filter(&(&1.workspace_id in workspace_ids))
  end

  defp session_has_other_registrations?(session_id) when is_integer(session_id) do
    registrations_by_session(session_id) != []
  end

  defp session_registrations_unchanged?(session_id, display_url) do
    session_id
    |> registrations_by_session()
    |> Enum.all?(&(&1.display_url == display_url))
  end

  # Panes self-register over POST /preview/panes without forward-auth headers,
  # so a control session opened here would navigate the Playwright browser
  # unauthenticated (401) behind ForwardAuth. Derive the workspace's
  # X-Auth-Request-Email header at registration so the very first navigation is
  # authenticated. An explicit "default_headers" map in the registration attrs
  # wins when present.
  defp pane_default_headers(workspace, attrs) do
    case Map.get(attrs, "default_headers") || Map.get(attrs, :default_headers) do
      headers when is_map(headers) and map_size(headers) > 0 -> headers
      _ -> Workspaces.forward_auth_headers(workspace) || %{}
    end
  end

  defp resolve_workspace(attrs) when is_map(attrs) do
    cond do
      is_map(Map.get(attrs, "workspace")) or is_map(Map.get(attrs, :workspace)) ->
        ws = Map.get(attrs, "workspace") || Map.get(attrs, :workspace)
        {:ok, WorkspaceContext.prepare(ws)}

      id = string_param(attrs, "workspace_id") || string_param(attrs, :workspace_id) ->
        case Workspaces.get(id) do
          {:ok, workspace} ->
            {:ok, workspace}

          {:error, _} ->
            {:ok, %{id: id, metadata: %{}}}
        end

      cwd = string_param(attrs, "cwd") || string_param(attrs, :cwd) ->
        case Workspaces.attach_folder(cwd) do
          {:ok, workspace} -> {:ok, workspace}
          {:error, :not_a_directory} -> {:error, :workspace_not_found}
          {:error, _} = error -> error
        end

      true ->
        {:error, :workspace_not_found}
    end
  end

  defp normalize_url(url) when is_binary(url) do
    expanded =
      case Regex.run(~r/^:(\d+)(\/.*)?$/, url) do
        [_, port, path] -> "http://localhost:#{port}#{path}"
        [_, port] -> "http://localhost:#{port}/"
        _ -> Url.normalize_localhost(url)
      end

    {:ok, expanded}
  end

  defp normalize_url(_), do: {:error, :missing_url}

  # Registration/navigation accept any well-formed http(s) URL — including
  # external sites and dynamic dev-server ports — the same way a browser tab
  # would. The origin allowlist in Previews.trusted_url?/2 is for a narrower
  # job: deciding whether an *already-open* control session's navigation
  # stayed same-origin (see Origin.within_origin?), not gating what a pane
  # may be registered/navigated to in the first place.
  defp validate_trusted_url(_workspace, url) do
    if Url.http_url?(url) do
      :ok
    else
      {:error, :untrusted_url}
    end
  end

  defp require_trusted_preview_url(url) do
    if Url.http_url?(url) do
      :ok
    else
      {:error, :untrusted_url}
    end
  end

  defp allowed_origins(workspace, control_url) do
    control_origin =
      case Url.origin_of(control_url) do
        origin when is_binary(origin) -> [origin]
        _ -> []
      end

    (Url.allowed_origins(workspace) ++ control_origin)
    |> Enum.uniq()
  end

  defp control_url_for(url) when is_binary(url) do
    with %URI{} = uri <- URI.parse(url),
         true <- devide_app_url?(uri),
         port <- Application.get_env(:dev_ide, :preview_loopback_port, 4000) do
      %URI{uri | scheme: "http", host: "127.0.0.1", port: port}
      |> URI.to_string()
    else
      _ -> url
    end
  end

  defp control_url_for(url), do: url

  defp devide_loopback_url?(%URI{} = uri) do
    port = Application.get_env(:dev_ide, :preview_loopback_port, 4000)

    uri.scheme in ["http", "https"] and uri.host in ["localhost", "127.0.0.1", "0.0.0.0"] and
      case uri.port do
        ^port -> true
        nil when port in [80, 443] -> true
        _ -> false
      end
  end

  defp devide_app_url?(%URI{host: host}) when is_binary(host) do
    host in configured_devide_hosts()
  end

  defp devide_app_url?(_), do: false

  defp configured_devide_hosts do
    [
      host_from_url(Application.get_env(:dev_ide, :preview_app_url)),
      get_in(Application.get_env(:dev_ide, :deployment, []), [:default_host])
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp host_from_url(url) when is_binary(url) do
    URI.parse(url).host
  end

  defp host_from_url(_), do: nil

  defp parse_viewport(nil), do: nil
  defp parse_viewport(""), do: nil

  defp parse_viewport(viewport) when is_binary(viewport) do
    case Regex.run(~r/^(\d+)x(\d+)$/i, viewport) do
      [_, width, height] ->
        %{width: String.to_integer(width), height: String.to_integer(height)}

      _ ->
        nil
    end
  end

  defp preview_title(url), do: "preview " <> url

  defp broadcast_registered(registration) do
    payload = broadcast_payload(registration)

    for workspace_id <- WorkspaceAliases.viewer_ids(registration.workspace_id) do
      Phoenix.PubSub.broadcast(DevIde.PubSub, "preview:" <> workspace_id, {
        :preview_pane_registered,
        payload
      })
    end

    :ok
  end

  defp broadcast_removed(registration) do
    payload = Map.take(broadcast_payload(registration), [:pane_id, :workspace_id, :preview_id])

    for workspace_id <- WorkspaceAliases.viewer_ids(registration.workspace_id) do
      Phoenix.PubSub.broadcast(DevIde.PubSub, "preview:" <> workspace_id, {
        :preview_pane_removed,
        payload
      })
    end

    :ok
  end

  defp broadcast_payload(registration) do
    %{
      pane_id: registration.pane_id,
      workspace_id: registration.workspace_id,
      preview_id: registration.preview_id,
      control_session_id: registration.control_session_id,
      tmux_session: registration.tmux_session,
      url: registration.url,
      display_url: registration.display_url,
      source_url: Map.get(registration, :source_url),
      viewport: registration.viewport,
      shared: Map.get(registration, :shared, false),
      source_pane_id: Map.get(registration, :source_pane_id),
      placement: Map.get(registration, :placement),
      anchor_pane_id: Map.get(registration, :anchor_pane_id),
      anchor_window_id: Map.get(registration, :anchor_window_id),
      pane_window_id: Map.get(registration, :pane_window_id)
    }
  end

  defp record_activity(registration, event, summary, metadata \\ %{}) do
    _ =
      PreviewActivity.record(%{
        workspace_id: registration.workspace_id,
        pane_id: registration.pane_id,
        preview_id: registration.preview_id,
        session_id: registration.control_session_id,
        source: :preview_pane,
        event: event,
        summary: summary,
        metadata:
          Map.merge(
            %{
              url: registration.url,
              display_url: registration.display_url,
              mode: preview_mode(registration)
            },
            metadata
          )
      })

    :ok
  end

  defp activity_event("preview_pane.navigated"), do: "navigated"
  defp activity_event("preview_pane.control_navigated"), do: "control_navigated"
  defp activity_event("preview_pane.snapshot_shown"), do: "screenshot_updated"
  defp activity_event(_), do: "updated"

  defp activity_summary("preview_pane.navigated"), do: "pane navigated"
  defp activity_summary("preview_pane.control_navigated"), do: "control navigation synced"
  defp activity_summary("preview_pane.snapshot_shown"), do: "snapshot updated"
  defp activity_summary(_), do: "preview pane updated"

  defp preview_mode(%{display_url: display_url}) when is_binary(display_url) do
    if String.contains?(display_url, "/preview-artifacts/"),
      do: "snapshot",
      else: "iframe"
  end

  defp preview_mode(_), do: "unknown"

  defp emit_audit!(action, registration) do
    Audit.emit!(%{
      action: action,
      workspace_id: registration.workspace_id,
      actor_id: "system",
      target_type: "preview_pane",
      target_ref: registration.pane_id,
      metadata: %{
        pane_id: registration.pane_id,
        preview_id: registration.preview_id,
        control_session_id: registration.control_session_id,
        url: registration.url,
        display_url: registration.display_url,
        shared: Map.get(registration, :shared, false),
        source_pane_id: Map.get(registration, :source_pane_id),
        placement: Map.get(registration, :placement),
        anchor_pane_id: Map.get(registration, :anchor_pane_id),
        anchor_window_id: Map.get(registration, :anchor_window_id),
        pane_window_id: Map.get(registration, :pane_window_id),
        viewport: registration.viewport,
        tmux_session: registration.tmux_session
      }
    })
  end

  defp require_binary(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(_, error), do: {:error, error}

  defp string_param(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp truthy_param?(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when value in [true, "true", "1", "yes"] -> true
      _ -> false
    end
  end
end
