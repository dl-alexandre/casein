defmodule PreviewCtl.Origin do
  @moduledoc """
  Generic http(s) preview URL primitives.

  Workspace-specific allowlists (manager domains, detected ports, etc.)
  are assembled by the host application and passed into these predicates.
  """

  @localhost_hosts ~w(localhost 127.0.0.1 0.0.0.0)

  @doc "True when the URL targets loopback (browser-local only)."
  @spec localhost_url?(String.t() | term()) :: boolean()
  def localhost_url?(url) when is_binary(url) do
    case URI.parse(normalize_localhost(url)) do
      %URI{host: host} when host in @localhost_hosts -> true
      _ -> false
    end
  end

  def localhost_url?(_), do: false

  @doc "Normalize loopback hosts to localhost for consistent trust checks."
  @spec normalize_localhost(String.t() | term()) :: String.t() | term()
  def normalize_localhost(url) when is_binary(url) do
    url
    |> String.replace(~r/^http:\/\/0\.0\.0\.0:/i, "http://localhost:")
    |> String.replace(~r/^https:\/\/0\.0\.0\.0:/i, "https://localhost:")
    |> String.replace(~r/^http:\/\/127\.0\.0\.1:/i, "http://localhost:")
    |> String.replace(~r/^https:\/\/127\.0\.0\.1:/i, "https://localhost:")
  end

  def normalize_localhost(other), do: other

  @doc "True when the URL is an embeddable HTTP(S) preview URL."
  @spec trusted_embed?(String.t(), [String.t()]) :: boolean()
  def trusted_embed?(url, allowed_origins \\ localhost_origins())

  def trusted_embed?(url, _allowed_origins) when is_binary(url) do
    http_url?(url)
  end

  def trusted_embed?(_, _), do: false

  @doc "True when the URL has an HTTP(S) scheme, host, and valid port."
  @spec http_url?(String.t() | term()) :: boolean()
  def http_url?(url) when is_binary(url) do
    url = normalize_localhost(url)

    with %URI{scheme: scheme, host: host} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- is_binary(host) and host != "",
         port when is_integer(port) and port > 0 and port < 65_536 <-
           uri.port || default_port(scheme) do
      true
    else
      _ -> false
    end
  end

  def http_url?(_), do: false

  @doc "Extract `scheme://host:port` from a URL."
  @spec origin_of(String.t() | term()) :: String.t() | nil
  def origin_of(url) when is_binary(url) do
    uri = URI.parse(normalize_localhost(url))

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      port = uri.port || default_port(uri.scheme)
      "#{uri.scheme}://#{uri.host}:#{port}"
    end
  end

  def origin_of(_), do: nil

  @doc "True when `path_or_url` resolves to an HTTP(S) preview URL."
  @spec within_origin?(String.t(), String.t(), [String.t()]) :: boolean()
  def within_origin?(path_or_url, base_url, allowed_origins)
      when is_binary(path_or_url) and is_binary(base_url) and is_list(allowed_origins) do
    resolved = resolve_against(path_or_url, base_url)
    trusted_embed?(resolved, allowed_origins)
  end

  def within_origin?(_, _, _), do: false

  @doc "Resolve a relative path against a base URL."
  @spec resolve_against(String.t(), String.t()) :: String.t()
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

  @doc "Default localhost origins for common dev ports."
  @spec localhost_origins() :: [String.t()]
  def localhost_origins do
    for scheme <- ["http", "https"],
        host <- @localhost_hosts,
        port <- common_dev_ports() do
      "#{scheme}://#{host}:#{port}"
    end
  end

  @doc "Common localhost dev server ports."
  @spec common_dev_ports() :: [integer()]
  def common_dev_ports, do: [80, 443, 3000, 4000, 5173, 8080, 9000]

  defp default_port("https"), do: 443
  defp default_port(_), do: 80
end
