defmodule Casein.Origin do
  @moduledoc """
  Installation-stable identity for this Casein origin.

  The public id is derived from the endpoint secret rather than a URL, so a
  hostname or LAN address change does not create a second mobile profile. An
  explicit `:origin_id`/`:origin_display_name` application setting can be used
  by managed installations.
  """

  @id_prefix "casein_"
  @id_context "casein-mobile-origin-v1"

  @spec id() :: String.t()
  def id do
    case configured_string(:origin_id) do
      nil ->
        secret = Application.get_env(:casein, :origin_identity_secret)

        unless is_binary(secret) and byte_size(secret) >= 32 do
          raise "Casein origin identity requires a stable endpoint secret_key_base"
        end

        digest =
          :crypto.mac(:hmac, :sha256, secret, @id_context)
          |> binary_part(0, 16)
          |> Base.url_encode64(padding: false)

        @id_prefix <> digest

      configured ->
        configured
    end
  end

  @spec display_name(String.t() | nil) :: String.t()
  def display_name(base_url \\ nil) do
    configured_string(:origin_display_name) ||
      inferred_display_name(base_url || endpoint_base_url())
  end

  @spec public_descriptor(String.t() | nil) :: map()
  def public_descriptor(base_url \\ nil) do
    %{id: id(), display_name: display_name(base_url)}
  end

  @spec pairing_descriptor(String.t()) :: map()
  def pairing_descriptor(base_url) when is_binary(base_url) do
    public_descriptor(base_url)
    |> Map.merge(%{
      name: display_name(base_url),
      base_url: base_url,
      socket_url: base_url <> "/socket/websocket",
      token_exchange_url: base_url <> "/api/device-links/exchange",
      audience: "casein"
    })
  end

  defp configured_string(key) do
    case Application.get_env(:casein, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  end

  defp endpoint_base_url do
    case Application.get_env(:casein, CaseinWeb.Endpoint, []) |> Keyword.get(:url, []) do
      url when is_list(url) ->
        case Keyword.get(url, :host) do
          host when is_binary(host) -> "https://" <> host
          _ -> nil
        end

      %{host: host} when is_binary(host) ->
        "https://" <> host

      _ ->
        nil
    end
  end

  defp inferred_display_name(nil), do: "Casein"

  defp inferred_display_name(base_url) do
    host = URI.parse(base_url).host || ""
    normalized = String.downcase(host)

    cond do
      String.contains?(normalized, "devbox") -> "Devbox"
      local_host?(normalized) -> "Local Mac"
      host == "" -> "Casein"
      true -> host
    end
  end

  defp local_host?(host) do
    host in ["localhost", "127.0.0.1", "::1"] or
      String.ends_with?(host, ".local") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "192.168.")
  end
end
