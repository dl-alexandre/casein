defmodule CaseinMob.OriginIdentity do
  @moduledoc false

  @deprecated_devbox_origin "https://devide.devbox.milcgroup.com"

  @spec legacy_id(String.t()) :: String.t()
  def legacy_id(url) when is_binary(url) do
    digest =
      :crypto.hash(:sha256, "casein-mobile-legacy-origin-v1:" <> normalize_url(url))
      |> binary_part(0, 12)
      |> Base.url_encode64(padding: false)

    "legacy_" <> digest
  end

  @spec display_name(String.t()) :: String.t()
  def display_name(url) when is_binary(url) do
    host = URI.parse(url).host || ""
    normalized = String.downcase(host)

    cond do
      String.contains?(normalized, "devbox") -> "Devbox"
      local_host?(normalized) -> "Local Mac"
      host == "" -> "Casein"
      true -> host
    end
  end

  @spec normalize_url(String.t()) :: String.t()
  def normalize_url(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    port =
      case {uri.scheme, uri.port} do
        {"https", 443} -> nil
        {"http", 80} -> nil
        {_scheme, value} -> value
      end

    %URI{
      uri
      | scheme: downcase(uri.scheme),
        host: downcase(uri.host),
        port: port,
        path: nil,
        query: nil,
        fragment: nil
    }
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  @spec deprecated_origin?(String.t()) :: boolean()
  def deprecated_origin?(url) when is_binary(url) do
    normalize_url(url) == @deprecated_devbox_origin
  end

  def deprecated_origin?(_url), do: false

  defp downcase(value) when is_binary(value), do: String.downcase(value)
  defp downcase(value), do: value

  defp local_host?(host) do
    host in ["localhost", "127.0.0.1", "::1"] or
      String.ends_with?(host, ".local") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "192.168.")
  end
end
