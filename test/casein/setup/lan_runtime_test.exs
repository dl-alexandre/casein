defmodule Casein.Setup.LanRuntimeTest do
  use ExUnit.Case, async: true

  alias Casein.Setup.LanRuntime

  test "prepare_units keeps backend and edge service paths separate" do
    config =
      LanRuntime.config(
        backend_port: 4999,
        build_path: "/tmp/casein-lan-build-test",
        group: "dev",
        home: "/tmp",
        home_workspace_path: "/tmp",
        lan_host: "casein.test",
        lan_ip: "127.0.0.1",
        listen_port: 8080,
        mise_path: "/usr/bin/mise",
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd",
        unit_dir: "/tmp/systemd",
        user: "dev",
        workdir: File.cwd!(),
        workspace: "home",
        workspaces_root: "/tmp/casein-workspaces"
      )

    paths = LanRuntime.prepare_units!(config)

    on_exit(fn ->
      paths.backend_service_path
      |> Path.dirname()
      |> File.rm_rf()
    end)

    assert Path.basename(paths.backend_service_path) == "devide-lan.service"
    assert Path.basename(paths.edge_service_path) == "devide-lan-http-edge.service"
    assert Path.basename(paths.socket_path) == "devide-lan-http-edge.socket"

    commands = LanRuntime.install_commands(paths, config)

    assert Enum.any?(commands, &Enum.member?(&1, paths.backend_service_path))
    assert Enum.any?(commands, &Enum.member?(&1, paths.edge_service_path))
  end

  test "config defaults the home workspace path to the target user's home" do
    config =
      LanRuntime.config(
        home: "/home/dev",
        mise_path: "/usr/bin/mise",
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd",
        user: "dev"
      )

    assert config.workspace == "home"
    assert config.home_workspace_path == "/home/dev"
  end

  test "rejects unsafe workspace names" do
    config = LanRuntime.config(workspace: "../bad", mise_path: "/usr/bin/mise")

    assert {:error, "invalid workspace name \"../bad\""} = LanRuntime.validate(config)
  end

  test "rejects unsafe home workspace paths" do
    config =
      LanRuntime.config(
        home_workspace_path: "../bad",
        mise_path: "/usr/bin/mise",
        proxyd_path: "/usr/lib/systemd/systemd-socket-proxyd"
      )

    assert {:error, "invalid home workspace path \"../bad\""} = LanRuntime.validate(config)
  end

  test "status lines distinguish managed readiness from a manual backend" do
    lines =
      LanRuntime.status_lines(%{
        backend_url: "http://127.0.0.1:4000/",
        canonical_url: "http://r630.local/",
        checks: [
          {:backend_service, false, "devide-lan.service is inactive"},
          {:backend_listener, true, "127.0.0.1:4000 accepts TCP"}
        ],
        config: %{lan_ip: "192.168.1.240"},
        ip_probe: {:ok, 302},
        ip_url: "http://192.168.1.240/",
        manual_backend?: true,
        ready?: false
      })

    assert "DevIDE Managed LAN status" in lines
    assert "  MANAGED NOT READY http://r630.local/" in lines

    assert "  INFO      manual backend detected; URL works but devide-lan.service is inactive" in lines
  end
end
