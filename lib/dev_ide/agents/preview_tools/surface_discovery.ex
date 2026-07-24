defmodule Casein.Agents.PreviewTools.SurfaceDiscovery do
  @moduledoc false

  alias Casein.Agents.PreviewTools.{ControlSession, WorkspaceResolution}
  alias Casein.PreviewActivity
  alias Casein.PreviewPanes
  alias Casein.Previews
  alias Casein.Previews.{EnvPorts, PortProbe, Surface, SurfaceResolver, Url, WorkspaceContext}

  @doc "List discoverable preview surfaces for agent planning."
  @spec surfaces(map(), map()) :: {:ok, map()} | {:error, term()}
  def surfaces(workspace, params \\ %{}) when is_map(workspace) and is_map(params) do
    workspace = WorkspaceResolution.prepare(workspace)
    active_by_origin = active_pane_registrations_by_origin(workspace)

    surfaces =
      Previews.discover_surfaces(
        workspace,
        surface_resolver_opts(params, runtime_required: false)
      )

    liveness = surface_liveness(surfaces)

    payload =
      surfaces
      |> Enum.map(&surface_payload(&1, active_by_origin, params, liveness))
      |> Enum.sort_by(&{&1.active, &1.server_active}, :desc)

    recommendable = Enum.filter(payload, & &1.server_active)
    recommendation = if recommendable == [], do: payload, else: recommendable

    {:ok,
     %{surfaces: payload}
     |> put_preview_next(
       "preview_open",
       preview_open_next_args(workspace, recommendation, liveness)
     )}
  end

  # Loopback registrations outlive their servers (a reaped worktree leaves its
  # runtime surface behind), so listing probes each unique loopback port the
  # same way preview_open's preflight would connect. Public URLs stay unprobed.
  defp surface_liveness(surfaces) do
    if Application.get_env(:dev_ide, :preview_surface_probe, true) do
      surfaces
      |> Enum.filter(&probeable_surface?/1)
      |> Enum.map(& &1.port)
      |> surface_prober().()
    else
      %{}
    end
  end

  defp probeable_surface?(%Surface{} = surface) do
    is_integer(surface.port) and Url.localhost_url?(surface.url)
  end

  defp surface_prober do
    case Application.get_env(:dev_ide, :preview_surface_prober) do
      {mod, fun} -> &apply(mod, fun, [&1])
      fun when is_function(fun, 1) -> fun
      _ -> &PortProbe.probe/1
    end
  end

  defp surface_liveness_status(%Surface{} = surface, liveness) do
    if probeable_surface?(surface) do
      case Map.fetch(liveness, surface.port) do
        {:ok, true} -> "alive"
        {:ok, false} -> "dead"
        :error -> "unprobed"
      end
    else
      "unprobed"
    end
  end

  # Index the live embedded preview panes for this workspace by origin so a
  # discovered surface can be tagged with the pane that is currently rendered
  # beside the user. Origin-only match tolerates path differences (a pane sitting
  # on /foo still resolves to its :5173 surface).
  @doc false
  def active_panes_by_origin(workspace) do
    workspace
    |> active_pane_registrations_by_origin()
    |> Map.new(fn {origin, registration} -> {origin, registration.pane_id} end)
  end

  @doc false
  def active_pane_registrations_by_origin(workspace) do
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

  @doc false
  def resolve_url(workspace, surface, params) do
    opts =
      surface_resolver_opts(params,
        runtime_required: boolean_param(params, :runtime_required) == true
      )

    prepared = WorkspaceResolution.prepare(workspace)

    case SurfaceResolver.resolve_open_surface(prepared, surface, opts) do
      {:ok, %Surface{url: url} = resolved} when is_binary(url) ->
        chosen = prefer_scoped_local_server(prepared, surface, resolved)
        {:ok, chosen.url, preview_source(chosen, resolved)}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :surface_not_found}
    end
  end

  # A worktree that boots its own `mix phx.server` on an ephemeral port shows up
  # only as a low-priority terminal `localhost:PORT` surface, so a default "app"
  # open resolves to the shared, workspace-wide manager URL instead of the
  # worktree's server. When exactly one live localhost server is detected that
  # is NOT one of the workspace's advertised service ports, prefer it so the
  # preview reflects the caller's worktree work. Runtime-provisioned surfaces
  # already win in `resolve_open_surface/3` and are left untouched here; an
  # ambiguous match (two or more live candidates) keeps the shared URL.
  @doc false
  @spec prefer_scoped_local_server(map(), String.t() | atom() | nil, Surface.t()) :: Surface.t()
  def prefer_scoped_local_server(workspace, requested, %Surface{} = resolved) do
    if scoped_local_server_preference_enabled?() and
         default_app_surface_request?(requested) and
         shared_app_surface?(resolved) do
      case scoped_local_app_surface(workspace) do
        %Surface{} = local -> local
        nil -> resolved
      end
    else
      resolved
    end
  end

  # Provenance of the surface a default open landed on, so callers can tell the
  # user which server they are actually looking at (worktree vs shared) instead
  # of the swap being silent. `preferred` is the surface after
  # `prefer_scoped_local_server/3`; `resolved` is what the resolver returned.
  @doc false
  @spec preview_source(Surface.t(), Surface.t()) :: map()
  def preview_source(%Surface{source: :detected, name: "app", port: port}, %Surface{} = resolved) do
    %{via: "worktree_local", port: port, overrode: resolved.url}
  end

  def preview_source(%Surface{source: :runtime, port: port}, _resolved) do
    drop_nil(%{via: "runtime", port: port})
  end

  def preview_source(%Surface{name: "app", url: url} = surface, _resolved) do
    if Url.localhost_url?(url),
      do: drop_nil(%{via: "local", port: surface.port}),
      else: %{via: "shared_manager"}
  end

  def preview_source(%Surface{name: name, port: port}, _resolved) do
    drop_nil(%{via: "surface", surface: name, port: port})
  end

  defp drop_nil(map), do: :maps.filter(fn _k, v -> not is_nil(v) end, map)

  defp scoped_local_server_preference_enabled? do
    Application.get_env(:dev_ide, :preview_prefer_scoped_local_server, true)
  end

  # Only the implicit/explicit "app" open is eligible; a caller asking for a
  # named surface (tidewave, api, a specific localhost:PORT, base:app, …) means
  # exactly what they typed.
  defp default_app_surface_request?(requested) do
    to_string(requested || "app") in ["", "app"]
  end

  # A shared surface is a non-loopback manager/host "app" URL — the public
  # workspace-wide server we want to override. Loopback, runtime, and detected
  # surfaces are already worktree/local-scoped.
  defp shared_app_surface?(%Surface{name: "app", url: url, source: source})
       when source in [:manager, :host] do
    not Url.localhost_url?(url)
  end

  defp shared_app_surface?(_surface), do: false

  defp scoped_local_app_surface(workspace) do
    case live_scoped_local_ports(workspace) do
      [port] ->
        %Surface{
          name: "app",
          url: WorkspaceContext.localhost_url(port),
          title: "App (worktree :#{port})",
          port: port,
          source: :detected
        }

      _ ->
        nil
    end
  end

  # Detected localhost ports minus the workspace's advertised service ports and
  # preview-router infrastructure ports, filtered to those actually accepting
  # connections. What remains is an ad-hoc dev server booted inside a worktree.
  defp live_scoped_local_ports(workspace) do
    candidates =
      workspace
      |> detected_ports()
      |> Enum.reject(&(&1 in reserved_local_ports(workspace)))
      |> Enum.uniq()

    case candidates do
      [] ->
        []

      ports ->
        liveness = surface_prober().(ports)
        Enum.filter(ports, &(Map.get(liveness, &1) == true))
    end
  end

  defp detected_ports(workspace) do
    workspace
    |> metadata_map()
    |> metadata_value(:detected_ports)
    |> List.wrap()
    |> Enum.filter(&is_integer/1)
  end

  defp reserved_local_ports(workspace) do
    advertised =
      workspace
      |> metadata_map()
      |> metadata_value(:ports)
      |> case do
        ports when is_map(ports) -> ports |> Map.values() |> Enum.filter(&is_integer/1)
        _ -> []
      end

    [EnvPorts.router_port(), EnvPorts.router_admin_port(), EnvPorts.current_port() | advertised]
    |> Enum.uniq()
  end

  defp metadata_map(workspace) do
    case Map.get(workspace, :metadata) || Map.get(workspace, "metadata") do
      m when is_map(m) -> m
      _ -> %{}
    end
  end

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp surface_payload(%Surface{} = surface, active_by_origin, params, liveness) do
    registration = Map.get(active_by_origin, Url.origin_of(surface.url))
    pane_id = registration && registration.pane_id
    visibility = surface_visibility(registration)
    operator_visible = visibility.browser_loaded == true
    liveness_status = surface_liveness_status(surface, liveness)

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
      server_active: liveness_status != "dead",
      server_status: surface_server_status(surface, params, liveness_status),
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

  defp surface_visibility(nil),
    do: ControlSession.preview_visibility_from_activity_for_surface([])

  defp surface_visibility(%{} = registration) do
    registration.workspace_id
    |> PreviewActivity.recent_pane(registration.pane_id, 20)
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
    |> ControlSession.preview_visibility_from_activity_for_surface()
  end

  defp surface_server_status(%Surface{} = surface, params, liveness_status) do
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
      liveness: liveness_status,
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
    do: Previews.discover_surfaces(WorkspaceResolution.prepare(workspace))

  defp put_preview_next(payload, tool, args) do
    payload
    |> Map.put(:next_tool, tool)
    |> Map.put(:next_arguments, args)
  end

  defp preview_open_next_args(workspace, [surface | _], liveness) do
    args = %{workspace_id: workspace_id(workspace)}
    port = Map.get(surface, :port)
    # A public surface still carries its loopback port number; never steer the
    # caller onto a port the listing probe just saw refuse connections.
    port_recommendable? = is_integer(port) and Map.get(liveness, port, true)

    cond do
      port_recommendable? ->
        args |> Map.put(:mode, "localhost") |> Map.put(:port, port) |> compact_map()

      is_binary(Map.get(surface, :name)) and surface.name != "" ->
        args |> Map.put(:mode, "app") |> Map.put(:surface, surface.name) |> compact_map()

      true ->
        args |> Map.put(:mode, "app") |> compact_map()
    end
  end

  defp preview_open_next_args(workspace, _surfaces, _liveness),
    do: %{workspace_id: workspace_id(workspace), mode: "app"} |> compact_map()

  defp workspace_id(workspace) when is_map(workspace),
    do: Map.get(workspace, :id) || Map.get(workspace, "id")

  defp workspace_id(_), do: nil

  defp compact_map(map) do
    map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()
  end

  defp string_param(params, key) when is_map(params) and is_atom(key) do
    case Map.get(params, Atom.to_string(key)) || Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp boolean_param(params, key) do
    value = Map.get(params, Atom.to_string(key)) || Map.get(params, key)

    case value do
      value when value in [true, false] -> value
      value when value in ["true", "1", "yes"] -> true
      value when value in ["false", "0", "no"] -> false
      _ -> nil
    end
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

  defp port_param(params) do
    case Map.get(params, "port") || Map.get(params, :port) do
      port when is_integer(port) ->
        port

      port when is_binary(port) ->
        case Integer.parse(port) do
          {value, ""} -> value
          _ -> {:error, :invalid_port}
        end

      nil ->
        nil

      _ ->
        {:error, :invalid_port}
    end
  end
end
