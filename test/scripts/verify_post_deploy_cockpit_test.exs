defmodule Scripts.VerifyPostDeployCockpitTest do
  @moduledoc """
  Hermetic guards for the #378 post-deploy authenticated cockpit gate.

  Never talks to the live release. Pins the contracts that have burned operators:
  curl -f must not appear on health probes, lingering canaries must not be
  treated as the live instance, and the evidence path must stay redaction-safe.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify_post_deploy_cockpit.sh", __DIR__)
  @acceptance Path.expand("../../docs/desktop/windows_mobile_acceptance.md", __DIR__)

  test "script exists, is executable, and has valid shell syntax" do
    assert File.exists?(@script)
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "health probes never use curl -f (401 body must remain visible)" do
    content = File.read!(@script)

    # The whole point of this gate: /health → 401 is healthy.
    assert content =~ "/health"
    assert content =~ "401"
    assert content =~ "auth-enforcing" || content =~ "alive and auth"

    # curl invocations that capture status must use -w http_code and -o body,
    # never -f (which exits non-zero and hides 4xx bodies).
    refute content =~ ~r/curl[^\n]*-f[^\n]*\/health/
    refute content =~ ~r/curl[^\n]*-fsS[^\n]*health/

    # Positive shape: status written via -w, body via -o.
    assert content =~ ~r/-w '%\{http_code\}'/
    assert content =~ ~r/-o /
  end

  test "live instance is resolved from current.sock, not every casein unit" do
    content = File.read!(@script)

    assert content =~ "current.sock"
    assert content =~ "resolve_live_instance"
    assert content =~ "lingering"
    assert content =~ ~r/casein-\[0-9a-f\]\{16\}/
    # Must not treat systemctl is-active casein (the non-existent alias) as truth.
    refute content =~ ~r/systemctl is-active ["']?casein["']?$/m
    refute content =~ "systemctl is-active casein\n"
  end

  test "requires deployed SHA to match origin tip unless drift is explicitly allowed" do
    content = File.read!(@script)

    assert content =~ "CASEIN_GIT_REVISION"
    assert content =~ "ORIGIN_REF"
    assert content =~ "--allow-drift"
    assert content =~ "CASEIN_ALLOW_DEPLOY_DRIFT"
    assert content =~ "last-deploy"
  end

  test "authenticated MCP path is read-only (list/topology/surfaces, no open/mutate)" do
    content = File.read!(@script)

    assert content =~ "terminal_list_sessions"
    assert content =~ "terminal_topology"
    assert content =~ "preview_surfaces"
    assert content =~ "CASEIN_API_TOKEN"
    assert content =~ "WORKSPACE_ID"

    refute content =~ "preview_open"
    refute content =~ "preview_click"
    refute content =~ "terminal_send_command"
    refute content =~ "terminal_send_keys"
  end

  test "refuses to hand-edit the live release tree" do
    content = File.read!(@script)

    assert content =~ "/opt/casein/release"
    # Mentions the forbidden path as a rule, never as a write target.
    refute content =~ ~r/\b(rm|mv|cp|sed|tee)\b[^\n]*\/opt\/casein\/release/
  end

  test "evidence JSON is redacted: no bearer tokens dumped into the artifact" do
    content = File.read!(@script)

    assert content =~ "--evidence"
    assert content =~ "verdict"
    assert content =~ "scrub_surfaces"
    # Evidence builder must not print the raw bearer into the JSON file.
    refute content =~ ~r/evidence\[.CASEIN_API_TOKEN/
  end

  test "acceptance doc points operators at this gate for #378" do
    doc = File.read!(@acceptance)
    assert doc =~ "378"
    assert doc =~ "verify_post_deploy_cockpit"
  end

  test "help path exits zero and names the issue" do
    {out, status} = System.cmd("bash", [@script, "--help"], stderr_to_stdout: true)
    assert status == 0
    assert out =~ "378"
    assert out =~ "--evidence"
  end
end
