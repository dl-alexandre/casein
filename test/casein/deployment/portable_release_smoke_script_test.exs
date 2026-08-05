defmodule Casein.Deployment.PortableReleaseSmokeScriptTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../../scripts/portable-release-smoke.sh", __DIR__)
  @compose Path.expand("../../../docker-compose.yml", __DIR__)
  @dockerfile Path.expand("../../../Dockerfile", __DIR__)
  @deploy_script Path.expand("../../../scripts/deploy-devbox-release.sh", __DIR__)
  @poller_script Path.expand("../../../scripts/deploy-poller.sh", __DIR__)
  @caddy_helper Path.expand("../../../scripts/lib/caddy-upstream.sh", __DIR__)

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
    assert text =~ "CASEIN_RELEASE_PROFILE: ${CASEIN_RELEASE_PROFILE:-portable}"
  end

  test "production container uses the writable runtime user's home" do
    text = File.read!(@dockerfile)

    assert text =~ "HOME=/home/casein"
    refute text =~ "HOME=/app"
  end

  test "devbox activation uses the renamed release entrypoint and socket cleaner" do
    text = File.read!(@deploy_script)
    caddy_helper = File.read!(@caddy_helper)

    assert text =~ ~s("${STAGING}/bin/casein")
    assert text =~ ~s(ExecStartPre=${ACTIVE_RELEASE}/bin/clean_casein_socket)
    assert text =~ ~s("${ACTIVE_RELEASE}/bin/casein" start)
    assert text =~ "*/priv/scripts/casein-preview"
    assert text =~ "*/priv/scripts/casein-curl.sh"
    assert text =~ "casein-agent-state.sh casein-codex-notify.sh"
    assert text =~ ~s(RUN_ROOT="${CASEIN_RUN_ROOT:-/run/casein}")
    assert text =~ ~s(CURRENT_SYMLINK="${CASEIN_CURRENT_SOCK:-${RUN_ROOT}/current.sock}")
    assert text =~ ~s(source "${DEPLOY_SCRIPT_SELF_DIR}/lib/caddy-upstream.sh")
    assert caddy_helper =~ "casein_caddy_admin_curl -fsS -X PATCH"
    assert text =~ "casein_canonical_route_attests_caddy_unavailable"
    assert text =~ ~s|token="$(casein_read_casein_api_token "${ENV_FILE}")"|
    refute text =~ "awk -F= '/^CASEIN_API_TOKEN/"
    assert caddy_helper =~ "unix//run/casein/current.sock"
    assert caddy_helper =~ "casein_caddy_admin_curl() {\n  curl "
    assert caddy_helper =~ ~s(--connect-timeout "${CASEIN_CADDY_ADMIN_CONNECT_TIMEOUT}")
    assert caddy_helper =~ ~s(--max-time "${CASEIN_CADDY_ADMIN_MAX_TIME}")
    assert caddy_helper =~ "casein_canonical_route_attests_caddy_unavailable"
    assert caddy_helper =~ ~s(--proto '=https')
    assert caddy_helper =~ "casein_read_casein_api_token"
    refute caddy_helper =~ "sudo curl"
    refute text =~ "sudo curl -fsS -X PATCH"
    refute text =~ ~s(INST_DIR="/run/casein/instances")
    refute text =~ ~s(CURRENT_SYMLINK="/run/casein/current.sock")
  end

  test "poller uses the same canonical Caddy-unavailable attestation" do
    text = File.read!(@poller_script)

    assert text =~ "canonical_route_attests_current_handoff"
    assert text =~ "casein_canonical_route_attests_caddy_unavailable"
    assert text =~ ~s(casein_read_casein_api_token "$ENV_FILE")
    refute text =~ "awk -F= '/^CASEIN_API_TOKEN/"

    assert text =~
             ~s(local host configured_socket="" current_target="" trusted_direct_dial="")

    assert text =~
             ~s(casein_reconcile_caddy_upstream "$host" repair "$trusted_direct_dial")

    assert text =~
             ~r|current_target=".*?".*?configured_socket.*?current_target.*?trusted_direct_dial="unix/\$\{configured_socket\}"|s

    assert text =~
             ~r|CADDY_RECONCILE_OUTCOME="not_attempted".*?if \[ .* != .* \]; then\n    log "refusing Caddy reconciliation.*?\n    return 1|s

    assert text =~ "canonical Caddy upstream repair failed"
  end
end
