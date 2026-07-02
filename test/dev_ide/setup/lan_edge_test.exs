defmodule DevIDE.Setup.LanEdgeTest do
  use ExUnit.Case, async: true

  alias DevIDE.Setup.LanEdge

  test "socket unit listens on the configured edge port" do
    text = LanEdge.socket_unit_text(443)

    assert text =~ "Description=DevIDE LAN HTTPS edge socket"
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
end
