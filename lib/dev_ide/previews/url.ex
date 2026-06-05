defmodule DevIDE.Previews.Url do
  @moduledoc false
  @localhost_hosts ~w(localhost 127.0.0.1 0.0.0.0)

  @doc "Normalize loopback hosts to localhost for consistent trust checks."
  def normalize_localhost(url) when is_binary(url) do
    url
    |> String.replace(~r/^http:\/\/0\.0\.0\.0:/i, "http://localhost:")
    |> String.replace(~r/^https:\/\/0\.0\.0\.0:/i, "https://localhost:")
    |> String.replace(~r/^http:\/\/127\.0\.0\.1:/i, "http://localhost:")
    |> String.replace(~r/^https:\/\/127\.0\.0\.1:/i, "https://localhost:")
  end

  def normalize_localhost(other), do: other

  @doc "True when the URL is safe to embed as an in-cockpit iframe."
  def trusted_embed?(url) when is_binary(url) do
    url = normalize_localhost(url)

    with %URI{scheme: scheme, host: host} = uri <- URI.parse(url),
         true <- scheme in ["http", "https"],
         true <- host in @localhost_hosts,
         port when is_integer(port) and port > 0 and port < 65_536 <-
           uri.port || default_port(scheme) do
      true
    else
      _ -> false
    end
  end

  def trusted_embed?(_), do: false

  @doc "Valid http(s) URL with a localhost-class host."
  def valid_preview_url?(url) when is_binary(url), do: trusted_embed?(url)

  def valid_preview_url?(_), do: false

  defp default_port("https"), do: 443
  defp default_port(_), do: 80
end
