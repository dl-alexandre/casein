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
    GenServer.call(__MODULE__, {:list_for_workspace, workspace_id})
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

  def handle_call({:get_by_session, session_id}, _from, state) do
    {:reply, lookup_by_session(state.workspace_index, session_id), state}
  end

  def handle_call({:list_for_workspace, workspace_id}, _from, state) do
    {:reply, list_workspace_registrations(state.workspace_index, workspace_id), state}
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
             control_url: preview.metadata["control_url"] || url
           ) do
      display_url = session.metadata["display_url"] || preview.url

      registration = %{
        id: pane_id,
        pane_id: pane_id,
        preview_id: preview.id,
        control_session_id: session.id,
        url: url,
        display_url: display_url,
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
        emit_audit!("preview_pane.removed", registration)
        {:ok, state}
    end
  end

  defp open_preview(workspace, url, pane_id, attrs) do
    workspace = WorkspaceContext.prepare(workspace)

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
        "control_url" => url,
        "display_url" => url,
        "allowed_origins" => Url.allowed_origins(workspace)
      }
    })
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

  defp list_workspace_registrations(workspace_index, workspace_id) do
    workspace_index
    |> Map.get(workspace_id, [])
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
      url: registration.url,
      display_url: registration.display_url,
      viewport: registration.viewport
    }
  end

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
