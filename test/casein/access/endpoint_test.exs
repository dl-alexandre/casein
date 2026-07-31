defmodule Casein.Access.EndpointTest do
  use ExUnit.Case, async: true

  alias Casein.Access.Endpoint

  test "constructors set kind, scope, and defaults" do
    loopback = Endpoint.loopback("http://127.0.0.1:4000/")
    assert loopback.kind == :loopback
    assert loopback.base_url == "http://127.0.0.1:4000"
    assert loopback.auth == :session
    assert loopback.scope == :same_host
    assert loopback.advertised?

    lan = Endpoint.lan("http://casein.test", auth: :session)
    assert lan.kind == :lan
    assert lan.scope == :same_lan

    public = Endpoint.public_https("https://casein.example.com")
    assert public.kind == :public_https
    assert public.auth == :bearer
    assert public.scope == :any

    ssh = Endpoint.ssh_forward("http://127.0.0.1:18000")
    assert ssh.kind == :ssh_forward
    assert ssh.scope == :same_host

    tail = Endpoint.tailscale("https://box.tailnet.ts.net")
    assert tail.kind == :tailscale
    assert tail.scope == :same_tailnet
  end

  test "new/1 validates enums and base_url" do
    assert_raise ArgumentError, fn ->
      Endpoint.new(kind: :loopback, base_url: "not-a-url", auth: :session, scope: :same_host)
    end

    assert_raise ArgumentError, fn ->
      Endpoint.new(kind: :nope, base_url: "http://x", auth: :session, scope: :any)
    end
  end

  test "in_scope?/2 lets clients rule out endpoints without probing" do
    public = Endpoint.public_https("https://casein.example.com")
    lan = Endpoint.lan("http://192.168.1.10")
    tail = Endpoint.tailscale("https://box.tailnet.ts.net")
    loopback = Endpoint.loopback("http://127.0.0.1:4000")

    off_lan_phone = %{same_host?: false, same_lan?: false, same_tailnet?: false}
    on_lan_phone = %{same_host?: false, same_lan?: true, same_tailnet?: false}
    on_tailnet = %{same_host?: false, same_lan?: false, same_tailnet?: true}
    same_host = %{same_host?: true, same_lan?: true, same_tailnet?: false}

    assert Endpoint.in_scope?(public, off_lan_phone)
    refute Endpoint.in_scope?(lan, off_lan_phone)
    refute Endpoint.in_scope?(tail, off_lan_phone)
    refute Endpoint.in_scope?(loopback, off_lan_phone)

    assert Endpoint.in_scope?(lan, on_lan_phone)
    refute Endpoint.in_scope?(tail, on_lan_phone)

    assert Endpoint.in_scope?(tail, on_tailnet)
    refute Endpoint.in_scope?(lan, on_tailnet)

    assert Endpoint.in_scope?(loopback, same_host)
  end
end
