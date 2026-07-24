defmodule CaseinWeb.WorkspaceRoutes do
  @moduledoc """
  Canonical workspace UI routes.

  Filesystem path routes expose host path shape in the browser URL, so they are
  only emitted in trusted single-user LAN mode. Forward-auth deployments keep
  opaque `/workspaces/:id` URLs even when a workspace has a local host path.
  """

  use CaseinWeb, :verified_routes

  alias Casein.Workspaces.PathResolver
  alias CaseinWeb.Plugs.ForwardAuth

  @spec path_routes_trusted?() :: boolean()
  def path_routes_trusted? do
    truthy?(Application.get_env(:casein, :lan_mode)) and not ForwardAuth.enabled?()
  end

  @spec workspace_path(map() | String.t(), String.t() | nil) :: String.t()
  def workspace_path(workspace_or_id, host_id \\ nil)

  def workspace_path(%{} = workspace, host_id) do
    id = field(workspace, :id)
    path = field(workspace, :path) || field(workspace, :host_path)

    if local_host?(host_id) and path_routes_trusted?() do
      case PathResolver.route_for(path) do
        {:ok, route} -> route
        :error -> id_workspace_path(id, host_id)
      end
    else
      id_workspace_path(id, host_id)
    end
  end

  def workspace_path(id, host_id) when is_binary(id), do: id_workspace_path(id, host_id)

  defp id_workspace_path(id, host_id) when is_binary(id) and id != "" do
    if local_host?(host_id),
      do: ~p"/workspaces/#{id}",
      else: ~p"/workspaces/#{id}?#{[host: host_id]}"
  end

  defp id_workspace_path(_id, _host_id), do: ~p"/workspaces"

  defp local_host?(host_id), do: host_id in [nil, "", "local"]

  defp field(map, key) when is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp truthy?(true), do: true
  defp truthy?(value) when is_binary(value), do: value in ~w(1 true TRUE yes YES on ON)
  defp truthy?(_value), do: false
end
