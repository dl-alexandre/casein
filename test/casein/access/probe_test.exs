defmodule Casein.Access.ProbeTest do
  use ExUnit.Case, async: false

  alias Casein.Access.Endpoint
  alias Casein.Access.Probe
  alias Casein.TestSupport.HTTPStub

  test "no-bearer 302 from a public endpoint is alive" do
    stub = HTTPStub.open()

    HTTPStub.stub(stub, "GET", "/healthz", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://login.example/start")
      |> Plug.Conn.resp(302, "")
    end)

    endpoint = Endpoint.public_https("http://127.0.0.1:#{stub.port}")
    assert Probe.reachable?(endpoint, timeout_ms: 500)
  end

  test "connection refused is dead" do
    # Bind then close so the port is free and unaccepted.
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_ip, port}} = :inet.sockname(listen)
    :ok = :gen_tcp.close(listen)

    endpoint = Endpoint.loopback("http://127.0.0.1:#{port}")
    refute Probe.reachable?(endpoint, timeout_ms: 300)
  end

  test "2xx and 401/403 are alive; 5xx is dead" do
    stub = HTTPStub.open()

    HTTPStub.stub(stub, "GET", "/healthz", fn conn ->
      Plug.Conn.resp(conn, 200, "ok")
    end)

    assert Probe.reachable?("http://127.0.0.1:#{stub.port}", timeout_ms: 500)

    # Re-stub in place. Do NOT cycle down/up to change a status: `down/1` keeps
    # the port reserved, so an immediate `up/1` races the reservation and dies
    # with :eaddrinuse.
    for {status, body} <- [{401, "auth"}, {403, "forbidden"}] do
      HTTPStub.stub(stub, "GET", "/healthz", fn conn ->
        Plug.Conn.resp(conn, status, body)
      end)

      assert Probe.reachable?("http://127.0.0.1:#{stub.port}", timeout_ms: 500),
             "#{status} proves a server is present, so it must count as alive"
    end

    for status <- [500, 502, 503] do
      HTTPStub.stub(stub, "GET", "/healthz", fn conn ->
        Plug.Conn.resp(conn, status, "down")
      end)

      refute Probe.reachable?("http://127.0.0.1:#{stub.port}", timeout_ms: 500),
             "#{status} means the app behind the port is not serving"
    end
  end
end
