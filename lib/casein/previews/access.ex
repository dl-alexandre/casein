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

    * **Port** — the port must be declared or detected for that workspace
      (`workspace_owned_port?`), **or** registered by one of its preview panes
      *and* still pass the registerable-port rules (common dev / infrastructure
      ranges / owned). Registration alone is not an authorization primitive
      (#927): a pane registration that points at an arbitrary loopback port must
      not widen the proxy allowlist.
  """

  alias Casein.PreviewPanes
  alias Casein.Previews
  alias Casein.Previews.EnvPorts
  alias Casein.Previews.OwnOrigin
  alias Casein.Previews.Url
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
      (registered_preview_port?(workspace_id, port) and
         registerable_loopback_port?(port, workspace))
  end

  @doc """
  True when a loopback port may be **registered** (and thus later proxied) for
  this workspace.

  Used at registration time and re-checked at proxy time so a registration
  record cannot widen the allowlist beyond ports the workspace is allowed to
  publish (#927). Does **not** replace the #884 external-origin allowlist —
  that path is separate and stays fail-closed.
  """
  @spec registerable_loopback_port?(pos_integer(), workspace()) :: boolean()
  def registerable_loopback_port?(port, workspace)
      when is_integer(port) and port > 0 and port < 65_536 and is_map(workspace) do
    # Mirror WorkspaceContext / Url.port_allowed? plus Casein's partitioned
    # infrastructure bands (runtime-owned + preview-env allocators).
    Url.port_allowed?(port, workspace) or
      EnvPorts.runtime_preview_port?(port) or
      EnvPorts.preview_env_port?(port)
  end

  def registerable_loopback_port?(_, _), do: false

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
      registration_names_port?(registration, port)
    end)
  end

  defp registration_names_port?(registration, port) do
    preview_port(Map.get(registration, :url) || Map.get(registration, "url")) == port or
      preview_port(Map.get(registration, :display_url) || Map.get(registration, "display_url")) ==
        port or
      preview_port(Map.get(registration, :source_url) || Map.get(registration, "source_url")) ==
        port
  end

  @doc """
  Port a preview registration URL points at.

  Registrations store a direct loopback URL, a `/preview-proxy/<ws>/<port>` path,
  or an own-origin `pv-<port>-<ws>` host, so all three shapes resolve here.

  Order matters. The routed shapes are checked *before* the URI's own port,
  because `URI.parse/1` fills in the scheme default: an absolute proxy URL like
  `https://casein.example/preview-proxy/<ws>/4003/` parses as port 443, and
  answering 443 here would both deny the real port and quietly nominate
  `127.0.0.1:443` as a registered preview port. The URI port is only trusted for
  a URL that carries no routing of its own.
  """
  @spec preview_port(term()) :: pos_integer() | nil
  def preview_port(url) when is_binary(url) do
    uri = URI.parse(url)

    routed_port(uri) || explicit_uri_port(url, uri)
  end

  def preview_port(_url), do: nil

  defp routed_port(%URI{host: host, path: path}) do
    (is_binary(host) and host_port(host)) || proxy_path_port(path)
  end

  defp proxy_path_port("/preview-proxy/" <> _ = path), do: preview_proxy_port(path)
  defp proxy_path_port(_path), do: nil

  # `URI.parse/1` supplies the scheme's default port even when the URL never
  # named one, so only accept a port the authority actually spelled out.
  defp explicit_uri_port(url, %URI{port: port, host: host})
       when is_integer(port) and is_binary(host) do
    if String.contains?(url, "#{host}:#{port}"), do: port
  end

  defp explicit_uri_port(_url, _uri), do: nil

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
