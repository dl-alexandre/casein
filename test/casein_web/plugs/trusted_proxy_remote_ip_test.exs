defmodule CaseinWeb.Plugs.TrustedProxyRemoteIpTest do
  use Casein.TestCase, async: true

  import Plug.Conn
  import Plug.Test

  alias CaseinWeb.Plugs.TrustedProxyRemoteIp

  # Discoverability: these used to live only in device_link_rate_limit_test.exs,
  # which made path-mirroring coverage audits report this plug as untested.

  test "ignores spoofed X-Forwarded-For from a non-loopback peer" do
    conn =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {203, 0, 113, 50})
      |> put_req_header("x-forwarded-for", "198.51.100.99")
      |> TrustedProxyRemoteIp.call([])

    assert conn.remote_ip == {203, 0, 113, 50}
  end

  test "rewrites remote_ip from the rightmost non-loopback XFF hop only on loopback peers" do
    loopback =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.77, 10.0.0.1")
      |> TrustedProxyRemoteIp.call([])

    assert loopback.remote_ip == {10, 0, 0, 1}

    external =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {8, 8, 8, 8})
      |> put_req_header("x-forwarded-for", "203.0.113.77")
      |> TrustedProxyRemoteIp.call([])

    assert external.remote_ip == {8, 8, 8, 8}
  end

  test "ignores client-prepended XFF spoof (rightmost non-loopback wins)" do
    conn =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "6.6.6.6, 198.51.100.7")
      |> TrustedProxyRemoteIp.call([])

    assert conn.remote_ip == {198, 51, 100, 7}
  end

  test "leaves loopback peer when all XFF hops are loopback" do
    single =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "127.0.0.1")
      |> TrustedProxyRemoteIp.call([])

    assert single.remote_ip == {127, 0, 0, 1}

    multi =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "127.0.0.1, ::1")
      |> TrustedProxyRemoteIp.call([])

    assert multi.remote_ip == {127, 0, 0, 1}
  end

  test "fails closed on an unparseable rightmost XFF entry" do
    conn =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "198.51.100.7, not-an-ip")
      |> TrustedProxyRemoteIp.call([])

    assert conn.remote_ip == {127, 0, 0, 1}
  end

  test "rewrites from XFF when Bandit accepts a Unix-socket peer" do
    resolved =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {:error, :einval})
      |> put_req_header("x-forwarded-for", "198.51.100.44")
      |> TrustedProxyRemoteIp.call([])

    assert resolved.remote_ip == {198, 51, 100, 44}
  end
end
