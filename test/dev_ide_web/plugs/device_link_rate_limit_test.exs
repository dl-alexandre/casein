defmodule DevIdeWeb.Plugs.DeviceLinkRateLimitTest do
  use DevIDE.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias DevIdeWeb.Plugs.DeviceLinkRateLimit
  alias DevIdeWeb.Plugs.TrustedProxyRemoteIp

  # Unique path per test so Hammer buckets never collide across examples.
  defp path(suffix), do: "/api/device-links/exchange-test-#{suffix}"

  setup do
    prev = Application.get_env(:dev_ide, DeviceLinkRateLimit)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:dev_ide, DeviceLinkRateLimit, prev),
        else: Application.delete_env(:dev_ide, DeviceLinkRateLimit)
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

  test "TrustedProxyRemoteIp rewrites remote_ip from XFF only on loopback peers" do
    loopback =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> put_req_header("x-forwarded-for", "203.0.113.77, 10.0.0.1")
      |> TrustedProxyRemoteIp.call([])

    assert loopback.remote_ip == {203, 0, 113, 77}

    external =
      :post
      |> conn("/api/device-links/exchange")
      |> Map.put(:remote_ip, {8, 8, 8, 8})
      |> put_req_header("x-forwarded-for", "203.0.113.77")
      |> TrustedProxyRemoteIp.call([])

    assert external.remote_ip == {8, 8, 8, 8}
  end
end
