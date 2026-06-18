defmodule DevIDE.PreviewPanes do
  @moduledoc """
  In-memory registry of preview panes bound to tmux pane ids.

  Registers via the `devide-preview` CLI or direct API calls, creates
  `Preview` + `ControlSession` records through `PreviewControl`, subscribes
  to tmux topology updates to expire vanished panes, and broadcasts pane
  lifecycle on the workspace preview PubSub topic.
  """

  use GenServer

  alias DevIDE.Audit
  alias DevIDE.PreviewActivity
  alias DevIDE.PreviewControl
  alias DevIDE.Previews
  alias DevIDE.Previews.Url
  alias DevIDE.Previews.WorkspaceContext
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.Aliases, as: WorkspaceAliases

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
          tmux_session: String.t() | nil
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
    case :ets.lookup(@table, pane_id) do
      [{^pane_id, registration}] -> registration
      _ -> nil
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
    case lookup_by_session(state.workspace_index, session_id) do
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
    case lookup_by_session(state.workspace_index, session_id) do
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
    {:reply, lookup_by_session(state.workspace_index, session_id), state}
  end

  def handle_call({:list_for_workspace, workspace_ids}, _from, state) do
    {:reply, list_workspace_registrations(state.workspace_index, workspace_ids), state}
  end

  def handle_call(:clear, _from, _state) do
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

    state =
      if existing = get_by_pane(pane_id) do
        case do_deregister(existing.pane_id, state) do
          {:ok, next} -> next
          {:error, _, next} -> next
        end
      else
        state
      end

    tmux_session = string_param(attrs, "tmux_session") || string_param(attrs, :tmux_session)

    with {:ok, pane_id} <- require_binary(pane_id, :missing_pane_id),
         {:ok, url} <- normalize_url(string_param(attrs, "url") || string_param(attrs, :url)),
         {:ok, workspace} <- resolve_workspace(attrs),
         :ok <- validate_trusted_url(workspace, url),
         viewport <-
           parse_viewport(string_param(attrs, "viewport") || string_param(attrs, :viewport)),
         {:ok, preview} <- open_preview(workspace, url, pane_id, attrs),
         {:ok, session} <-
           PreviewControl.open_for_preview(workspace, preview,
             actor_id: string_param(attrs, "actor_id") || string_param(attrs, :actor_id),
             control_url: preview.metadata["control_url"] || url,
             storage_profile:
               string_param(attrs, "storage_profile") || string_param(attrs, :storage_profile),
             storage_profile_name:
               string_param(attrs, "storage_profile_name") ||
                 string_param(attrs, :storage_profile_name)
           ) do
      display_url = session.metadata["display_url"] || preview.url

      registration = %{
        id: pane_id,
        pane_id: pane_id,
        preview_id: preview.id,
        control_session_id: session.id,
        url: url,
        display_url: display_url,
        source_url: preview.metadata["source_url"],
        viewport: viewport,
        workspace_id: workspace.id,
        tmux_session: tmux_session
      }

      :ets.insert(@table, {pane_id, registration})

      state =
        state
        |> put_workspace_index(pane_id, workspace.id)
        |> maybe_subscribe_topology(tmux_session)

      broadcast_registered(registration)
      record_activity(registration, "registered", "preview pane registered")
      refresh_topology(tmux_session)
      emit_audit!("preview_pane.registered", registration)

      {:ok, registration, state}
    end
  end

  defp do_deregister(pane_id, state) do
    case get_by_pane(pane_id) do
      nil ->
        {:error, :not_found, state}

      registration ->
        :ets.delete(@table, pane_id)
        _ = PreviewControl.close_session(registration.control_session_id)

        if preview =
             Previews.get_for_workspace(registration.preview_id, registration.workspace_id) do
          _ = Previews.close(preview)
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
        navigate_as_snapshot(registration, new_display_url)
      else
        persist_registration_url(registration, new_display_url, "preview_pane.navigated")
      end
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
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

    registration =
      %{registration | url: display_url, display_url: display_url}
      |> Map.put(:source_url, source_url)

    with :ok <-
           update_preview_url(
             registration.preview_id,
             registration.workspace_id,
             display_url,
             source_url
           ) do
      :ets.insert(@table, {registration.pane_id, registration})
      broadcast_registered(registration)
      record_activity(registration, activity_event(audit_action), activity_summary(audit_action))
      refresh_topology(registration.tmux_session)
      emit_audit!(audit_action, registration)

      {:ok, registration}
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

    if is_binary(control_origin) and current_origin == control_origin do
      replace_origin(current_url, registration.display_url)
    else
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
      origin when is_binary(origin) -> {:ok, origin <> path <> "?fit=preview"}
      _ -> {:error, :missing_artifact_origin}
    end
  end

  defp artifact_display_url(_registration, _), do: {:error, :invalid_artifact_path}

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
    origin = Url.origin_of(url)
    is_binary(origin) and origin in preview_allowed_origins(registration)
  end

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
        "display_url" => url,
        "allowed_origins" => allowed_origins(workspace, control_url)
      }
    })
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

    Enum.reduce(stale, state, fn pane_id, acc ->
      case do_deregister(pane_id, acc) do
        {:ok, next} -> next
        {:error, _, next} -> next
      end
    end)
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
    ids = Map.get(state.workspace_index, workspace_id, [])
    %{state | workspace_index: Map.put(state.workspace_index, workspace_id, [pane_id | ids])}
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

  defp validate_trusted_url(workspace, url) do
    workspace = WorkspaceContext.prepare(workspace)

    if Previews.trusted_url?(url, workspace) do
      :ok
    else
      {:error, :untrusted_url}
    end
  end

  defp require_trusted_preview_url(url) do
    if Url.valid_preview_url?(url, Url.allowed_origins(nil)) do
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
      viewport: registration.viewport
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
end
