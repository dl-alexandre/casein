defmodule Casein.Deployment.PortableReleaseSmokeScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/portable-release-smoke.sh", __DIR__)
  @compose Path.expand("../../../docker-compose.yml", __DIR__)
  @dockerfile Path.expand("../../../Dockerfile", __DIR__)

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

    assert text =~ "HOME=/home/dev_ide"
    refute text =~ "HOME=/app"
  end

  test "production builder copies the current local path dependencies" do
    text = File.read!(@dockerfile)

    assert text =~ "COPY casein_core casein_core"
    assert text =~ "COPY casein_preview_browser casein_preview_browser"
    refute text =~ "COPY dev_ide_core dev_ide_core"
    refute text =~ "COPY dev_ide_preview_browser dev_ide_preview_browser"
  end
end
