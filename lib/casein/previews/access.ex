defmodule Casein.Previews.Access do
  @moduledoc """
  The single authorization gate for reaching a workspace's loopback dev server.

  Two front doors lead to the same loopback ports — the `/preview-proxy` path
  proxy and the own-origin `pv-*` hostnames (`Casein.Previews.OwnOrigin`) — and
  they must not drift apart, because both of them turn a URL supplied by a
  browser into a connection to `127.0.0.1`. Both call `authorize/3`.

  Two things are checked:

    * **Viewer** — the requester must be able to access the workspace
      (`Casein.Workspaces.viewer_terminal_owner?/2`). "Not found" and "not yours"
      are deliberately answered the same way so the response cannot be used to
      probe which workspaces exist.

    * **Port** — the port must be declared or detected for that workspace, or
      registered by one of its preview panes. Common dev ports are not implicitly
      trusted; without this an authorized viewer of workspace A could reach a peer
      workspace's loopback service.
  """

  alias Casein.PreviewPanes
  alias Casein.Previews
  alias Casein.Previews.OwnOrigin
  alias Casein.Workspaces

  @type workspace :: map()

  @doc """
  Authorize `viewer` to reach `port` on `workspace_id`'s loopback interface.

  Returns the workspace on success so callers that need it (the path proxy) do
  not have to load it twice. The two denials are kept distinct because they mean
  different things to whoever is debugging a preview: `:forbidden` is "not your
  workspace" (deliberately indistinguishable from "no such workspace"), while
  `{:error, :port_not_allowed}` is "your workspace, but nothing is published on
  that port".
  """
  @spec authorize(map() | nil, String.t(), integer()) ::
          {:ok, workspace()} | :forbidden | {:error, :bad_port | :port_not_allowed}
  def authorize(viewer, workspace_id, port) when is_binary(workspace_id) do
    with {:ok, port} <- validate_port(port),
         {:ok, workspace} <- load_authorized(viewer, workspace_id) do
      if port_allowed?(port, workspace_id, workspace),
        do: {:ok, workspace},
        else: {:error, :port_not_allowed}
    end
  end

  def authorize(_viewer, _workspace_id, _port), do: :forbidden

  @doc "Parse and range-check a port supplied as a string or integer."
  @spec validate_port(term()) :: {:ok, pos_integer()} | {:error, :bad_port}
  def validate_port(port) when is_integer(port) and port > 0 and port < 65_536, do: {:ok, port}

  def validate_port(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} -> validate_port(parsed)
      _ -> {:error, :bad_port}
    end
  end

  def validate_port(_port), do: {:error, :bad_port}

  @doc "True when `port` is a loopback port this workspace is allowed to expose."
  @spec port_allowed?(pos_integer(), String.t(), workspace()) :: boolean()
  def port_allowed?(port, workspace_id, workspace) do
    Previews.workspace_owned_port?(port, workspace) or
      registered_preview_port?(workspace_id, port)
  end

  defp load_authorized(viewer, workspace_id) do
    auth = viewer && Map.get(viewer, :email)

    case Workspaces.get(workspace_id, auth) do
      {:ok, workspace} ->
        if Workspaces.viewer_terminal_owner?(workspace, viewer || %{}),
          do: {:ok, workspace},
          else: :forbidden

      # Don't distinguish "not found" from "not yours" — avoid leaking existence.
      _ ->
        :forbidden
    end
  end

  defp registered_preview_port?(workspace_id, port) do
    workspace_id
    |> PreviewPanes.list_for_workspace()
    |> Enum.any?(fn registration ->
      preview_port(registration.url) == port or preview_port(registration.display_url) == port
    end)
  end

  @doc """
  Port a preview registration URL points at.

  Registrations store either a direct loopback URL, a `/preview-proxy/<ws>/<port>`
  path, or an own-origin `pv-<port>-<ws>` host, so all three shapes resolve here.
  """
  @spec preview_port(term()) :: pos_integer() | nil
  def preview_port(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host_port(host) || uri_port(url)
      %URI{path: "/preview-proxy/" <> _ = path} -> preview_proxy_port(path)
      _ -> nil
    end
  end

  def preview_port(_url), do: nil

  defp uri_port(url) do
    case URI.parse(url) do
      %URI{port: port} when is_integer(port) -> port
      _ -> nil
    end
  end

  defp host_port(host) do
    case OwnOrigin.parse_host(host) do
      {:ok, %{port: port}} -> port
      :error -> nil
    end
  end

  defp preview_proxy_port(path) do
    case String.split(path, "/", parts: 5) do
      ["", "preview-proxy", _workspace_id, port, _rest] -> parse_proxy_port(port)
      ["", "preview-proxy", _workspace_id, port] -> parse_proxy_port(port)
      _ -> nil
    end
  end

  defp parse_proxy_port(port) do
    case Integer.parse(port) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end
end
