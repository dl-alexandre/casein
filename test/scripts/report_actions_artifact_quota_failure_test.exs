defmodule Scripts.ReportActionsArtifactQuotaFailureTest do
  @moduledoc """
  Hermetic coverage of scripts/report-actions-artifact-quota-failure.sh (#889).

  Asserts the diagnose stays a hard fail and that desktop workflows wire it
  without continue-on-error / soft-pass tricks.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/report-actions-artifact-quota-failure.sh", __DIR__)
  @macos Path.expand("../../.github/workflows/macos-desktop.yml", __DIR__)
  @windows Path.expand("../../.github/workflows/windows-desktop.yml", __DIR__)

  test "script has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "exits non-zero and names account/org quota, not a build failure" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "artifact-quota-summary-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)
    summary = Path.join(tmp, "summary.md")
    on_exit(fn -> File.rm_rf!(tmp) end)

    {out, status} =
      System.cmd(
        "bash",
        [@script],
        env: [
          {"GITHUB_STEP_SUMMARY", summary},
          {"CASEIN_DESKTOP_PLATFORM", "macOS"},
          {"CASEIN_DESKTOP_WORKFLOW_NAME", "macOS desktop package"}
        ],
        stderr_to_stdout: true
      )

    assert status == 1, out
    assert out =~ "ACCOUNT/ORG"
    assert out =~ "Artifact storage quota"
    assert out =~ "NOT a macOS build/sign/verify failure"
    assert out =~ "Rerunning this workflow until GitHub recalculates"
    assert out =~ "6–12h" or out =~ "6-12h"
    assert out =~ "continue-on-error"
    assert out =~ "REQUIRED"
    assert out =~ "::error title=Actions artifact quota (not a build failure)::"

    summary_body = File.read!(summary)
    assert summary_body =~ "honest red"
    assert summary_body =~ "ACCOUNT/ORG"
  end

  test "macos and windows desktop workflows wire diagnose without soft-pass", _context do
    for path <- [@macos, @windows] do
      body = File.read!(path)

      assert body =~ "report-actions-artifact-quota-failure.sh",
             "#{path} must call the quota diagnose script"

      assert body =~ "steps.upload_package.conclusion == 'failure'",
             "#{path} must gate diagnose on upload_package failure"

      assert body =~ "id: upload_package",
             "#{path} upload step must be id: upload_package"

      refute Regex.match?(~r/^\s*continue-on-error:\s*true/m, body),
             "#{path} must not use continue-on-error (would hide upload reds)"

      # Must not skip upload on failure or force green when quota is hit.
      refute body =~ "if: success() && false"
      refute Regex.match?(~r/upload-artifact[\s\S]{0,200}continue-on-error/m, body)
    end
  end
end
