defmodule CaseinMob.OriginIdentity do
  @moduledoc false

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
  def normalize_url(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp local_host?(host) do
    host in ["localhost", "127.0.0.1", "::1"] or
      String.ends_with?(host, ".local") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "192.168.")
  end
end
