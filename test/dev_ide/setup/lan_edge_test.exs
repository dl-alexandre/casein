defmodule Casein.Setup.LanEdgeTest do
  use ExUnit.Case, async: true

  alias Casein.Setup.LanEdge

  test "socket unit listens on the configured edge port" do
    text = LanEdge.socket_unit_text(443)

    assert text =~ "Description=Casein LAN HTTPS edge socket"
    assert text =~ "ListenStream=443"
    assert text =~ "WantedBy=sockets.target"
  end

  test "service unit proxies raw TLS to the configured backend" do
    text =
      LanEdge.service_unit_text(
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd",
        backend_host: "127.0.0.1",
        backend_port: 4443
      )

    assert text =~ "Requires=devide-lan-edge.socket"
    assert text =~ "ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:4443"
    assert text =~ "NoNewPrivileges=true"
  end

  test "write_units creates both systemd units" do
    dir =
      Path.join(System.tmp_dir!(), "devide-lan-edge-test-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)

    paths =
      LanEdge.write_units!(dir,
        listen_port: 8443,
        backend_host: "127.0.0.1",
        backend_port: 4443,
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd"
      )

    assert File.read!(paths.socket_path) =~ "ListenStream=8443"
    assert File.read!(paths.service_path) =~ "127.0.0.1:4443"
  end

  test "listener_open? rejects injection-shaped and malformed ports" do
    for bad <- ["443; touch /tmp/pwned", nil, 443.0, 0, -1, 70_000] do
      refute LanEdge.listener_open?(bad)
    end
  end

  test "listener_open? is true for an open local TCP port" do
    {:ok, ls} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(ls)

    try do
      assert LanEdge.listener_open?(port)
    after
      :gen_tcp.close(ls)
    end
  end

  test "listener_open? is false for a closed local TCP port" do
    {:ok, ls} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(ls)
    :ok = :gen_tcp.close(ls)

    refute LanEdge.listener_open?(port)
  end
end
