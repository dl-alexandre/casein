defmodule Casein.Deployment.PortableReleaseSmokeScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/portable-release-smoke.sh", __DIR__)
  @compose Path.expand("../../../docker-compose.yml", __DIR__)
  @dockerfile Path.expand("../../../Dockerfile", __DIR__)
  @deploy_script Path.expand("../../../scripts/deploy-devbox-release.sh", __DIR__)

  test "portable smoke script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "contract exercises product readiness, MCP, terminals, and workspace discovery" do
    text = File.read!(@script)

    assert text =~ "/healthz"
    assert text =~ "/api/terminals/mcp"
    assert text =~ "/api/smoke/terminal"
    assert text =~ "docker/smoke/Dockerfile"
    assert text =~ "/api/workspaces"
    assert text =~ ~s(CASEIN_PROFILE="portable")
  end

  test "generic Compose stack selects portable runtime and release profiles" do
    text = File.read!(@compose)

    assert text =~ "CASEIN_PROFILE: ${CASEIN_PROFILE:-portable}"
    assert text =~ "DEVIDE_RELEASE_PROFILE: ${DEVIDE_RELEASE_PROFILE:-portable}"
  end

  test "production container uses the writable runtime user's home" do
    text = File.read!(@dockerfile)

    assert text =~ "HOME=/home/casein"
    refute text =~ "HOME=/app"
  end

  test "devbox activation uses the renamed release entrypoint and socket cleaner" do
    text = File.read!(@deploy_script)

    assert text =~ ~s("${STAGING}/bin/casein")
    assert text =~ ~s(ExecStartPre=${ACTIVE_RELEASE}/bin/clean_casein_socket)
    assert text =~ ~s("${ACTIVE_RELEASE}/bin/casein" start)
    assert text =~ "*/priv/scripts/casein-preview"
    assert text =~ "*/priv/scripts/casein-curl.sh"
    assert text =~ "casein-agent-state.sh casein-codex-notify.sh"
    assert text =~ ~s(RUN_ROOT="${DEVIDE_RUN_ROOT:-/run/casein}")
    assert text =~ ~s(CURRENT_SYMLINK="${DEVIDE_CURRENT_SOCK:-${RUN_ROOT}/current.sock}")
    assert text =~ "unix//run/casein/current.sock"
    refute text =~ ~s("${STAGING}/bin/dev_ide")
    refute text =~ ~s(ExecStartPre=${ACTIVE_RELEASE}/bin/clean_devide_socket)
    refute text =~ ~s("${ACTIVE_RELEASE}/bin/dev_ide" start)
    refute text =~ "*/priv/scripts/devide-preview"
    refute text =~ "*/priv/scripts/devide-curl.sh"
    refute text =~ "devide-agent-state.sh devide-codex-notify.sh"
    refute text =~ ~s(INST_DIR="/run/devide/instances")
    refute text =~ ~s(CURRENT_SYMLINK="/run/devide/current.sock")
    refute text =~ "unix//run/devide/current.sock"
  end
end
