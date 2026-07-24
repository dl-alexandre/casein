defmodule Casein.Setup.LanServiceTest do
  use ExUnit.Case, async: true

  alias Casein.Setup.LanService

  @opts [
    backend_port: 4000,
    build_path: "/tmp/casein-lan-build-milc",
    group: "milc",
    home: "/home/milc",
    home_workspace_path: "/home/milc",
    lan_host: "r630.local",
    listen_port: 80,
    mise_path: "/usr/bin/mise",
    user: "milc",
    workdir: "/tmp/casein-agent-worktrees/lan-mode-20260624",
    workspace: "home",
    workspaces_root: "/tmp/casein_workspaces"
  ]

  test "service unit runs the LAN backend as the developer user" do
    text = LanService.service_unit_text(@opts)

    assert text =~ "Description=Casein LAN backend"
    assert text =~ "User=milc"
    assert text =~ "Group=milc"
    assert text =~ "WorkingDirectory=/tmp/casein-agent-worktrees/lan-mode-20260624"
    assert text =~ ~s(Environment="CASEIN_LAN_INSECURE_HTTP=true")
    assert text =~ ~s(Environment="CASEIN_LAN_HOST=r630.local")
    assert text =~ ~s(Environment="CASEIN_DEFAULT_WORKSPACE=home")
    assert text =~ ~s(Environment="CASEIN_HOME_WORKSPACE_PATH=/home/milc")
    assert text =~ "ExecStart=/usr/bin/mise exec -- mix phx.server"
    assert text =~ "KillMode=process"
    assert text =~ "WantedBy=multi-user.target"
  end

  test "write_unit creates the backend service unit" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "devide-lan-service-test-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    paths = LanService.write_unit!(dir, @opts)

    assert File.read!(paths.service_path) =~ "casein-lan-build-milc"
    assert Path.basename(paths.service_path) == "devide-lan.service"
  end
end
