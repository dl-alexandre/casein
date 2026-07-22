defmodule DevIDE.Previews.Url do
  @moduledoc false

  alias DevIDE.HostMode
  alias PreviewCtl.Origin

  @doc "True when the URL targets loopback (browser-local only)."
  defdelegate localhost_url?(url), to: Origin

  @doc "Normalize loopback hosts to localhost for consistent trust checks."
  defdelegate normalize_localhost(url), to: Origin

  @doc "True when the URL has an HTTP(S) scheme, host, and valid port."
  defdelegate http_url?(url), to: Origin

  @doc """
  Allowed origins for a workspace preview surface.

  Includes loopback dev servers and manager-owned workspace domains for v3.
  """
  def allowed_origins(nil), do: Origin.localhost_origins()

  def allowed_origins(workspace) when is_map(workspace) do
    (Origin.localhost_origins() ++
       workspace_domain_origins(workspace) ++
       workspace_port_origins(workspace) ++
       detected_port_origins(workspace) ++
       host_app_origins())
    |> Enum.uniq()
  end

  @doc """
  True when a localhost port may be opened for agent preview control.

  Allowed when the port is a common dev port, declared in workspace metadata,
  or detected from recent terminal output (after `WorkspaceContext.prepare/1`).
  """
  @spec port_allowed?(integer(), map()) :: boolean()
  def port_allowed?(port, workspace) when is_integer(port) and is_map(workspace) do
    valid_port?(port) and
      (port in Origin.common_dev_ports() or
         port in metadata_port_values(workspace) or
         port in detected_port_values(workspace))
  end

  def port_allowed?(_, _), do: false

  @doc """
  True when a localhost port belongs to the workspace itself.

  Unlike `port_allowed?/2`, this strict policy does not allow common dev ports
  unless workspace metadata declares or detects them.
  """
  @spec workspace_owned_port?(integer(), map()) :: boolean()
  def workspace_owned_port?(port, workspace) when is_integer(port) and is_map(workspace) do
    valid_port?(port) and
      (port in metadata_port_values(workspace) or
         port in detected_port_values(workspace))
  end

  def workspace_owned_port?(_, _), do: false

  @doc "Allowed localhost ports for a workspace, including common, metadata, and detected ports."
  @spec allowed_ports(map() | nil) :: [integer()]
  def allowed_ports(nil), do: Origin.common_dev_ports()

  def allowed_ports(workspace) when is_map(workspace) do
    (Origin.common_dev_ports() ++
       metadata_port_values(workspace) ++ detected_port_values(workspace))
    |> Enum.filter(&valid_port?/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "True when the URL is a trusted workspace preview origin."
  def trusted_embed?(url) when is_binary(url),
    do: Origin.trusted_embed?(url, Origin.localhost_origins())

  def trusted_embed?(url, allowed_origins) when is_binary(url) and is_list(allowed_origins),
    do: Origin.trusted_embed?(url, allowed_origins)

  def trusted_embed?(_, _), do: false

  @doc "Valid http(s) preview URL for the given allowlist."
  def valid_preview_url?(url, allowed_origins \\ nil)

  def valid_preview_url?(url, nil), do: Origin.trusted_embed?(url, Origin.localhost_origins())

  def valid_preview_url?(url, allowed_origins) when is_binary(url) and is_list(allowed_origins),
    do: Origin.trusted_embed?(url, allowed_origins)

  def valid_preview_url?(_, _), do: false

  @doc "Extract `scheme://host:port` from a URL."
  defdelegate origin_of(url), to: Origin

  @doc "True when `path_or_url` stays within the session's allowed origins."
  defdelegate within_origin?(path_or_url, base_url, allowed_origins), to: Origin

  @doc "Resolve a relative path against a base URL."
  defdelegate resolve_against(path_or_url, base_url), to: Origin

  defp host_app_origins do
    if HostMode.on_host?() do
      case Application.get_env(:dev_ide, :preview_app_url) do
        url when is_binary(url) and url != "" ->
          case Origin.origin_of(url) do
            origin when is_binary(origin) -> [origin]
            _ -> []
          end

        _ ->
          []
      end
    else
      []
    end
  end

  defp detected_port_origins(workspace) do
    for port <- detected_port_values(workspace),
        scheme <- ["http", "https"],
        host <- ~w(localhost 127.0.0.1 0.0.0.0) do
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp detected_port_values(workspace) do
    metadata(workspace)
    |> metadata_value(:detected_ports)
    |> List.wrap()
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
  end

  defp metadata_port_values(workspace) do
    metadata(workspace)
    |> metadata_value(:ports)
    |> case do
      ports when is_map(ports) ->
        ports
        |> Map.values()
        |> Enum.filter(&is_integer/1)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp valid_port?(port) when is_integer(port), do: port > 0 and port < 65_536

  defp workspace_port_origins(workspace) do
    metadata = metadata(workspace)
    ports = metadata_value(metadata, :ports) || %{}

    for {_key, port} <- ports,
        is_integer(port),
        scheme <- ["http", "https"],
        host <- ~w(localhost 127.0.0.1 0.0.0.0) do
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp workspace_domain_origins(workspace) do
    metadata = metadata(workspace)
    domain_base = metadata_value(metadata, :domain_base)

    if is_binary(domain_base) and domain_base != "" do
      # Apex (`domain_base`) is the v3 app host; `local.<domain_base>` is the
      # legacy (v2) app host. Allow both so either app surface is embeddable.
      for host <- [domain_base, "local.#{domain_base}"], scheme <- ["https", "http"] do
        "#{scheme}://#{host}:#{default_port(scheme)}"
      end
    else
      []
    end
  end

  defp metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(workspace) when is_map(workspace), do: workspace

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  defp default_port("https"), do: 443
  defp default_port(_), do: 80
end
