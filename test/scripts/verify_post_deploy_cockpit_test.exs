defmodule Scripts.VerifyPostDeployCockpitTest do
  @moduledoc """
  Hermetic guards for the #378 post-deploy authenticated cockpit gate.

  Never talks to the live release. Pins the contracts that have burned operators:
  curl -f must not appear on health probes, lingering canaries must not be
  treated as the live instance, fixture dry-run must not false-green drift,
  release identity (socket/unit/heartbeat) must agree, and human_remaining
  stays explicit until an operator attaches OAuth evidence.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify_post_deploy_cockpit.sh", __DIR__)
  @acceptance Path.expand("../../docs/desktop/windows_mobile_acceptance.md", __DIR__)
  @fixtures Path.expand("fixtures/post_deploy_cockpit", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "casein-378-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "script exists, is executable, and has valid shell syntax" do
    assert File.exists?(@script)
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "health probes never use curl -f (401 body must remain visible)" do
    content = File.read!(@script)

    assert content =~ "/health"
    assert content =~ "401"
    assert content =~ "auth-enforcing" || content =~ "alive and auth"

    refute content =~ ~r/curl[^\n]*-f[^\n]*\/health/
    refute content =~ ~r/curl[^\n]*-fsS[^\n]*health/

    assert content =~ ~r/-w '%\{http_code\}'/
    assert content =~ ~r/-o /
  end

  test "live instance is resolved from current.sock, not every casein unit" do
    content = File.read!(@script)

    assert content =~ "current.sock"
    assert content =~ "resolve_live_instance"
    assert content =~ "lingering"
    assert content =~ ~r/casein-\[0-9a-f\]\{16\}/
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

  test "release identity proves which process answered (pid triple + heartbeat version)" do
    content = File.read!(@script)

    assert content =~ "socket_peer_pid"
    assert content =~ "MainPID"
    assert content =~ "heartbeat"
    assert content =~ "identity mismatch"
    assert content =~ "stale canary"
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
    refute content =~ ~r/\b(rm|mv|cp|sed|tee)\b[^\n]*\/opt\/casein\/release/
  end

  test "evidence JSON is redacted and lists human_remaining checklist" do
    content = File.read!(@script)

    assert content =~ "--evidence"
    assert content =~ "verdict"
    assert content =~ "scrub_surfaces"
    assert content =~ "human_remaining"
    assert content =~ "need_template"
    assert content =~ "--require-operator-evidence"
    assert content =~ "operator evidence still required (exit 5)"
    refute content =~ ~r/evidence\[.CASEIN_API_TOKEN/
  end

  test "fixture mode is hermetic (no live I/O path when --fixture is set)" do
    content = File.read!(@script)

    assert content =~ "--fixture"
    assert content =~ "FIXTURE_DIR"
    assert content =~ "mode=fixture"
    # Must not false-green drift in fixture path.
    assert content =~ "expect_verdict"
  end

  test "acceptance doc points operators at this gate for #378" do
    doc = File.read!(@acceptance)
    assert doc =~ "378"
    assert doc =~ "verify_post_deploy_cockpit"
    assert doc =~ "--fixture" or doc =~ "human_remaining" or doc =~ "identity"
  end

  test "help path exits zero and names the issue" do
    {out, status} = System.cmd("bash", [@script, "--help"], stderr_to_stdout: true)
    assert status == 0
    assert out =~ "378"
    assert out =~ "--evidence"
    assert out =~ "--fixture"
    assert out =~ "--require-operator-evidence"
  end

  test "fixture green_allow_drift passes software checks and writes human_remaining", %{tmp: tmp} do
    evidence = Path.join(tmp, "green.json")
    fixture = Path.join(@fixtures, "green_allow_drift")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--fixture", fixture, "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "passed_with_allowed_drift"
    assert out =~ "NEED (human):"
    assert File.exists?(evidence)

    body = Jason.decode!(File.read!(evidence))
    assert body["schema"] == "casein_post_deploy_cockpit_evidence"
    assert body["schema_version"] == 2
    assert body["issue"] == 378
    assert body["mode"] == "fixture"
    assert body["verdict"] == "passed_with_allowed_drift"
    assert is_list(body["human_remaining"])
    assert length(body["human_remaining"]) >= 4
    assert Enum.any?(body["human_remaining"], &String.contains?(&1, "oauth_cockpit_load"))
    assert body["identity"]["matched"] == true
    assert body["health"]["path_health"]["http_code"] == "401"
    assert is_binary(body["need_template"])
    assert body["need_template"] =~ "NEED (human):"
    refute Map.has_key?(body, "CASEIN_API_TOKEN")
  end

  test "fixture green_tip_matched verdict is passed without allow-drift", %{tmp: tmp} do
    evidence = Path.join(tmp, "tip.json")
    fixture = Path.join(@fixtures, "green_tip_matched")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--fixture", fixture, "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 0, out
    body = Jason.decode!(File.read!(evidence))
    assert body["verdict"] == "passed"
    assert body["deploy"]["drift"] == false
  end

  test "fixture red_drift fails closed (does not false-green)", %{tmp: tmp} do
    evidence = Path.join(tmp, "red-drift.json")
    fixture = Path.join(@fixtures, "red_drift")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--fixture", fixture, "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 2, out
    body = Jason.decode!(File.read!(evidence))
    assert body["verdict"] == "failed_deploy"
    assert body["deploy"]["drift"] == true
    assert body["deploy"]["allow_drift"] == false
  end

  test "fixture red_identity fails when socket peer pid disagrees with unit", %{tmp: tmp} do
    evidence = Path.join(tmp, "red-id.json")
    fixture = Path.join(@fixtures, "red_identity")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--fixture", fixture, "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 2, out
    assert out =~ "identity mismatch" or out =~ "failed_deploy"
    body = Jason.decode!(File.read!(evidence))
    assert body["verdict"] == "failed_deploy"
    assert body["identity"]["matched"] == false
    assert Enum.any?(body["failures"], &String.contains?(&1, "identity mismatch"))
  end

  test "require-operator-evidence exits 5 when software is green", %{tmp: tmp} do
    evidence = Path.join(tmp, "need-op.json")
    fixture = Path.join(@fixtures, "green_tip_matched")

    {out, status} =
      System.cmd(
        "bash",
        [
          @script,
          "--fixture",
          fixture,
          "--evidence",
          evidence,
          "--require-operator-evidence"
        ],
        stderr_to_stdout: true
      )

    assert status == 5, out
    assert out =~ "operator evidence"
    body = Jason.decode!(File.read!(evidence))
    assert body["verdict"] == "passed"
    assert length(body["human_remaining"]) >= 4
  end
end
