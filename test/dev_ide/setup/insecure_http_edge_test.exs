defmodule DevIDE.Setup.InsecureHttpEdgeTest do
  use ExUnit.Case, async: true

  alias DevIDE.Setup.InsecureHttpEdge

  test "socket unit listens on the configured insecure HTTP port" do
    text = InsecureHttpEdge.socket_unit_text(80)

    assert text =~ "Description=DevIDE INSECURE LAN HTTP edge socket"
    assert text =~ "ListenStream=80"
    assert text =~ "WantedBy=sockets.target"
  end

  test "service unit proxies plain HTTP to the configured backend" do
    text =
      InsecureHttpEdge.service_unit_text(
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd",
        backend_host: "127.0.0.1",
        backend_port: 4000
      )

    assert text =~ "Requires=devide-lan-http-edge.socket"
    assert text =~ "Requires=devide-lan.service"
    assert text =~ "After=network.target devide-lan.service"
    assert text =~ "ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:4000"
    assert text =~ "NoNewPrivileges=true"
  end

  test "write_units creates both insecure HTTP systemd units" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "devide-lan-http-edge-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    paths =
      InsecureHttpEdge.write_units!(dir,
        listen_port: 8080,
        backend_host: "127.0.0.1",
        backend_port: 4000,
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd"
      )

    assert File.read!(paths.socket_path) =~ "ListenStream=8080"
    assert File.read!(paths.service_path) =~ "127.0.0.1:4000"
    assert File.read!(paths.service_path) =~ "Requires=devide-lan.service"
  end
end
