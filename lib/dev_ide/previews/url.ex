defmodule DevIDE.Previews.Url do
  @moduledoc false
  @localhost_hosts ~w(localhost 127.0.0.1 0.0.0.0)

  @doc "True when the URL targets loopback (browser-local only)."
  def localhost_url?(url) when is_binary(url) do
    case URI.parse(normalize_localhost(url)) do
      %URI{host: host} when host in @localhost_hosts -> true
      _ -> false
    end
  end

  def localhost_url?(_), do: false

  @doc "Normalize loopback hosts to localhost for consistent trust checks."
  def normalize_localhost(url) when is_binary(url) do
    url
    |> String.replace(~r/^http:\/\/0\.0\.0\.0:/i, "http://localhost:")
    |> String.replace(~r/^https:\/\/0\.0\.0\.0:/i, "https://localhost:")
    |> String.replace(~r/^http:\/\/127\.0\.0\.1:/i, "http://localhost:")
    |> String.replace(~r/^https:\/\/127\.0\.0\.1:/i, "https://localhost:")
  end

  def normalize_localhost(other), do: other

  @doc """
  Allowed origins for a workspace preview surface.

  Includes loopback dev servers and manager-owned workspace domains for v3.
  """
  def allowed_origins(nil), do: localhost_origins()

  def allowed_origins(workspace) when is_map(workspace) do
    (localhost_origins() ++
       workspace_domain_origins(workspace) ++ workspace_port_origins(workspace))
    |> Enum.uniq()
  end

  @doc "True when the URL is a trusted workspace preview origin."
  def trusted_embed?(url) when is_binary(url), do: trusted_embed?(url, localhost_origins())

  def trusted_embed?(url, allowed_origins) when is_binary(url) and is_list(allowed_origins) do
    url = normalize_localhost(url)

    with %URI{scheme: scheme, host: host} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- host_allowed?(host, allowed_origins),
         port when is_integer(port) and port > 0 and port < 65_536 <-
           uri.port || default_port(scheme) do
      true
    else
      _ -> false
    end
  end

  def trusted_embed?(_, _), do: false

  @doc "Valid http(s) preview URL for the given allowlist."
  def valid_preview_url?(url, allowed_origins \\ nil)

  def valid_preview_url?(url, nil), do: trusted_embed?(url, localhost_origins())

  def valid_preview_url?(url, allowed_origins) when is_binary(url) and is_list(allowed_origins),
    do: trusted_embed?(url, allowed_origins)

  def valid_preview_url?(_, _), do: false

  @doc "Extract `scheme://host:port` from a URL."
  def origin_of(url) when is_binary(url) do
    uri = URI.parse(normalize_localhost(url))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      port = uri.port || default_port(uri.scheme)
      "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end

  def origin_of(_), do: nil

  @doc "True when `path_or_url` stays within the session's allowed origins."
  def within_origin?(path_or_url, base_url, allowed_origins)
      when is_binary(path_or_url) and is_binary(base_url) and is_list(allowed_origins) do
    resolved = resolve_against(path_or_url, base_url)
    trusted_embed?(resolved, allowed_origins)
  end

  def within_origin?(_, _, _), do: false

  @doc "Resolve a relative path against a base URL."
  def resolve_against(path_or_url, base_url)
      when is_binary(path_or_url) and is_binary(base_url) do
    cond do
      String.starts_with?(path_or_url, ["http://", "https://"]) ->
        normalize_localhost(path_or_url)

      String.starts_with?(path_or_url, "/") ->
        base = URI.parse(base_url)
        "#{base.scheme}://#{base.host}:#{base.port || default_port(base.scheme)}#{path_or_url}"

      true ->
        URI.merge(base_url, path_or_url) |> URI.to_string()
    end
  end

  def resolve_against(path_or_url, _base_url), do: path_or_url

  defp localhost_origins do
    for scheme <- ["http", "https"],
        host <- @localhost_hosts,
        port <- common_dev_ports() do
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp common_dev_ports, do: [80, 443, 3000, 4000, 5173, 8080, 9000]

  defp workspace_port_origins(workspace) do
    metadata = metadata(workspace)
    ports = metadata_value(metadata, :ports) || %{}

    for {_key, port} <- ports,
        is_integer(port),
        scheme <- ["http", "https"],
        host <- @localhost_hosts do
      "#{scheme}://#{host}:#{port}"
    end
  end

  defp workspace_domain_origins(workspace) do
    metadata = metadata(workspace)
    domain_base = metadata_value(metadata, :domain_base)

    if is_binary(domain_base) and domain_base != "" do
      for scheme <- ["https", "http"] do
        "#{scheme}://#{domain_base}:#{default_port(scheme)}"
      end
    else
      []
    end
  end

  # Security predicate. A host matches when it equals an allowed origin's host or
  # is a subdomain of it ("." <> allowed_host). This intentionally admits service
  # subdomains (tidewave.<domain_base>, api.<domain_base>, etc.) under a workspace
  # domain — and, for localhost-class hosts, things like *.localhost.
  defp host_allowed?(host, allowed_origins) when is_binary(host) and is_list(allowed_origins) do
    Enum.any?(allowed_origins, fn allowed ->
      %URI{host: allowed_host} = URI.parse(allowed)
      host == allowed_host or String.ends_with?(host, "." <> allowed_host)
    end)
  end

  defp host_allowed?(_, _), do: false

  defp metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  defp metadata(workspace) when is_map(workspace), do: workspace

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp metadata_value(_, _), do: nil

  defp default_port("https"), do: 443
  defp default_port(_), do: 80
end
