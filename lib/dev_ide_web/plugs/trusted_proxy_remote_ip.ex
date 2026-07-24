defmodule CaseinWeb.Plugs.TrustedProxyRemoteIp do
  @moduledoc """
  Rewrites `conn.remote_ip` from a reverse-proxy forwarded header **only** when
  the direct peer is loopback.

  Casein binds loopback behind oauth2-proxy/Caddy, so every external client
  appears as `127.0.0.1` at Bandit. Without this plug, IP-keyed rate limits
  collapse into one global bucket.

  Trust model (fail closed):

    * Direct peer must be loopback (`127.0.0.0/8` or `::1`).
    * Only then is `x-forwarded-for` (rightmost non-loopback hop) or `x-real-ip` used.
    * Proxy-appended XFF entries are trustworthy from the right; client-prepended
      entries are not — so we walk right-to-left, skip our own loopback hops, and
      take the first parseable non-loopback address. Unparseable entries fail closed
      (no rewrite) rather than skipping deeper into client-controlled slots.
    * Spoofed forwarded headers from a non-loopback peer are ignored.
  """

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if loopback?(conn.remote_ip) do
      case forwarded_client_ip(conn) do
        {:ok, ip} -> %{conn | remote_ip: ip}
        :error -> conn
      end
    else
      conn
    end
  end

  defp forwarded_client_ip(conn) do
    cond do
      (xff = first_header(conn, "x-forwarded-for")) != nil ->
        xff
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reverse()
        |> rightmost_trusted_hop()

      (real = first_header(conn, "x-real-ip")) != nil ->
        parse_ip(real)

      true ->
        :error
    end
  end

  # Walk right-to-left (caller already reversed): skip loopback proxy hops; first
  # parseable non-loopback wins. Unparseable entry aborts the whole lookup.
  defp rightmost_trusted_hop([]), do: :error

  defp rightmost_trusted_hop([entry | rest]) do
    case parse_ip(entry) do
      {:ok, ip} ->
        if loopback?(ip), do: rightmost_trusted_hop(rest), else: {:ok, ip}

      :error ->
        :error
    end
  end

  defp first_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] when is_binary(value) and value != "" -> String.trim(value)
      _ -> nil
    end
  end

  defp parse_ip(nil), do: :error

  defp parse_ip(value) when is_binary(value) do
    value = value |> String.trim() |> strip_port()

    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  # Drop optional `:port` suffix (IPv4 only; bracketed IPv6 with port is rare
  # in these headers and rejected by parse_address if malformed).
  defp strip_port(value) do
    case String.split(value, ":", parts: 2) do
      [host, port] ->
        if String.match?(port, ~r/^\d+$/) and not String.contains?(host, ":") do
          host
        else
          value
        end

      _ ->
        value
    end
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?(_), do: false
end
