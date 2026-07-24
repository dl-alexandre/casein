defmodule CaseinWeb.Plugs.DeviceLinkRateLimitTest do
  use Casein.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias CaseinWeb.Plugs.DeviceLinkRateLimit
  alias CaseinWeb.Plugs.TrustedProxyRemoteIp

  # Unique path per test so Hammer buckets never collide across examples.
  defp path(suffix), do: "/api/device-links/exchange-test-#{suffix}"

  setup do
    prev = Application.get_env(:casein, DeviceLinkRateLimit)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:casein, DeviceLinkRateLimit, prev),
        else: Application.delete_env(:casein, DeviceLinkRateLimit)
    end)

    :ok
  end

  defp call_limited(conn, opts) do
    conn
    |> TrustedProxyRemoteIp.call([])
    |> DeviceLinkRateLimit.call(opts)
  end

  defp loopback_conn(path, xff) do
    :post
    |> conn(path)
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> put_req_header("x-forwarded-for", xff)
  end

  defp non_loopback_conn(path, peer_ip, xff) do
    :post
    |> conn(path)
    |> Map.put(:remote_ip, peer_ip)
    |> put_req_header("x-forwarded-for", xff)
  end

  defp unix_socket_conn(path, xff \\ nil) do
    conn =
      :post
      |> conn(path)
      |> Map.put(:remote_ip, {:error, :einval})

    if xff, do: put_req_header(conn, "x-forwarded-for", xff), else: conn
  end

  test "allows requests under the default 30/min limit and denies the 31st" do
    path = path("default-30")
    # Explicit scale/limit matches the plug defaults so the assertion is stable
    # even if Application env overrides are present in other tests.
    opts = [scale_ms: 60_000, limit: 30]

    for _ <- 1..30 do
      conn = call_limited(loopback_conn(path, "203.0.113.10"), opts)
      refute conn.halted
      refute conn.status == 429
    end

    denied = call_limited(loopback_conn(path, "203.0.113.10"), opts)

    assert denied.halted
    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
    assert %{"error" => "rate_limited"} = Jason.decode!(denied.resp_body)
  end

  test "isolates rate-limit buckets per resolved client IP" do
    path = path("per-ip")
    opts = [scale_ms: 60_000, limit: 2]

    for _ <- 1..2 do
      conn = call_limited(loopback_conn(path, "198.51.100.1"), opts)
      refute conn.halted
    end

    assert call_limited(loopback_conn(path, "198.51.100.1"), opts).status == 429

    # Different client IP (via trusted-proxy XFF) must not share the bucket.
    other = call_limited(loopback_conn(path, "198.51.100.2"), opts)
    refute other.halted
    refute other.status == 429
  end

  test "ignores spoofed X-Forwarded-For from a non-loopback peer" do
    path = path("spoofed-xff")
    opts = [scale_ms: 60_000, limit: 1]
    peer = {203, 0, 113, 50}

    first =
      call_limited(
        non_loopback_conn(path, peer, "198.51.100.99"),
        opts
      )

    refute first.halted

    # Same direct peer, different spoofed XFF — must still hit the peer bucket.
    spoofed_other_xff =
      call_limited(
        non_loopback_conn(path, peer, "203.0.113.200"),
        opts
      )

    assert spoofed_other_xff.halted
    assert spoofed_other_xff.status == 429

    # A genuine loopback-proxied client with that spoofed address is isolated.
    real_client =
      call_limited(loopback_conn(path, "198.51.100.99"), opts)

    refute real_client.halted
    refute real_client.status == 429
  end

  test "TrustedProxyRemoteIp rewrites remote_ip from rightmost non-loopback XFF hop only on loopback peers" do
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

  test "resolves Caddy's client IP when Bandit accepts a Unix-socket peer" do
    resolved =
      unix_socket_conn(
        "/api/device-links/exchange",
        "198.51.100.44"
      )
      |> TrustedProxyRemoteIp.call([])

    assert resolved.remote_ip == {198, 51, 100, 44}
  end

  test "does not crash when a Unix-socket request has no forwarded client IP" do
    result =
      unix_socket_conn(path("unix-without-xff"))
      |> call_limited(scale_ms: 60_000, limit: 1)

    refute result.halted
    refute result.status == 429
  end

  test "TrustedProxyRemoteIp ignores client-prepended XFF spoof (rightmost non-loopback wins)" do
    conn =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "6.6.6.6, 198.51.100.7")
      |> TrustedProxyRemoteIp.call([])

    assert conn.remote_ip == {198, 51, 100, 7}
  end

  test "TrustedProxyRemoteIp leaves loopback peer when all XFF hops are loopback" do
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

  test "TrustedProxyRemoteIp fails closed on unparseable rightmost XFF entry" do
    conn =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "198.51.100.7, not-an-ip")
      |> TrustedProxyRemoteIp.call([])

    assert conn.remote_ip == {127, 0, 0, 1}
  end
end
