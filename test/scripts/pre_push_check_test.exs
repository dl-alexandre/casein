defmodule Scripts.PrePushCheckTest do
  @moduledoc """
  Guards the pre-push gate's run-recording contract: the script must report
  its verdict to DevIDE via the terminal MCP `gate_report` tool, and that
  reporting must be fail-open on every path — a dead API, missing env, or
  missing python3 must never change the gate's exit code.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/pre-push-check.sh", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "reports the gate verdict through the gate_report terminal tool" do
    content = File.read!(@script)

    # Verdict reporting is wired as an EXIT trap so both pass and fail runs
    # report, and the trap itself can never flip the gate's exit code.
    assert content =~ "trap 'report_gate_result \"$?\" || true' EXIT"
    assert content =~ "\\\"name\\\":\\\"gate_report\\\""
    assert content =~ "\"workspace_id\": os.environ[\"DEVIDE_WORKSPACE_ID\"]"
  end

  test "gate reporting is fail-open on every path" do
    content = File.read!(@script)

    # Skipped silently without the workspace env vars.
    assert content =~
             "[[ -n \"${DEV_IDE_API_TOKEN:-}\" && -n \"${DEVIDE_WORKSPACE_ID:-}\" ]] || return 0"

    # Skipped when the helper binaries are missing.
    assert content =~ "command -v python3 >/dev/null 2>&1 || return 0"
    assert content =~ "command -v curl >/dev/null 2>&1 || return 0"

    # Short curl timeout, output swallowed, and never a gate failure.
    assert content =~ "--max-time 5"
    assert content =~ "-d \"${rpc_body}\" >/dev/null 2>&1 || true"
  end

  test "the last announced step is captured for failed_step" do
    content = File.read!(@script)

    assert content =~ "log() { printf '>>> %s\\n' \"$*\"; GATE_CURRENT_STEP=\"$*\"; }"
    assert content =~ "failed_step=\"${GATE_CURRENT_STEP}\""
  end
end
