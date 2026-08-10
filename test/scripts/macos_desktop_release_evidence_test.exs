defmodule Scripts.MacosDesktopReleaseEvidenceTest do
  @moduledoc """
  Linux-safe contract tests for the macOS desktop release-evidence harness
  (issue #382). These do not claim notarization passed — they lock the
  operator entrypoints, secrets hygiene, and durable evidence shape so a
  release Mac can finish the real gate without rediscovering the path.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @package Path.join(@repo_root, "scripts/package-macos-desktop.sh")
  @test_package Path.join(@repo_root, "scripts/test-macos-desktop-package.sh")
  @verify Path.join(@repo_root, "scripts/verify-macos-desktop-release.sh")
  @notarize Path.join(@repo_root, "scripts/notarize-macos-desktop.sh")
  @collect Path.join(@repo_root, "scripts/collect-macos-desktop-evidence.sh")
  @validate Path.join(@repo_root, "scripts/validate-macos-desktop-evidence.sh")
  @schema Path.join(@repo_root, "scripts/schemas/macos_desktop_release_evidence.schema.json")
  @fixtures Path.join(@repo_root, "test/fixtures/macos_desktop_release_evidence")
  @bundle Path.join(@repo_root, "native/casein_menubar/scripts/bundle.sh")
  @entitlements Path.join(@repo_root, "native/casein_menubar/Resources/Casein.entitlements")
  @workflow Path.join(@repo_root, ".github/workflows/macos-desktop.yml")
  @runbook Path.join(@repo_root, "docs/desktop/macos_release_evidence.md")

  @canonical_missing ["developer_id", "notary_profile", "signed_lifecycle"]

  test "release-evidence scripts exist, are executable, and have valid shell syntax" do
    for path <- [@package, @test_package, @verify, @notarize, @collect, @validate, @bundle] do
      assert File.exists?(path), "missing #{path}"
      assert executable?(path), "not executable: #{path}"
      assert {_, 0} = System.cmd("bash", ["-n", path])
    end

    assert File.exists?(@schema)
    schema = @schema |> File.read!() |> Jason.decode!()
    assert schema["$schema"]
    assert schema["properties"]["kind"]["const"] == "macos_desktop_release_evidence"
    assert schema["properties"]["issue"]["const"] == 382
  end

  test "hardened-runtime entitlements fixture is present and non-secret" do
    assert File.exists?(@entitlements)
    body = File.read!(@entitlements)
    assert body =~ "com.apple.security.cs.allow-jit"
    assert body =~ "com.apple.security.cs.allow-unsigned-executable-memory"
    assert body =~ "com.apple.security.cs.disable-library-validation"
    refute body =~ "BEGIN CERTIFICATE"
    refute body =~ "PRIVATE KEY"
    refute body =~ ~r/password\s*=\s*['\"][^'\"]+['\"]/i
  end

  test "Developer ID packaging path requires an explicit identity" do
    body = File.read!(@package)
    assert body =~ "CASEIN_REQUIRE_DEVELOPER_ID"
    assert body =~ "CASEIN_CODESIGN_IDENTITY"
    assert body =~ "collect-macos-desktop-evidence.sh"
    assert body =~ "codesign_identity"
  end

  test "bundle.sh enables hardened runtime only for non-ad-hoc identities" do
    body = File.read!(@bundle)
    assert body =~ ~s(--options runtime)
    assert body =~ "--timestamp"
    assert body =~ "CASEIN_CODESIGN_ENTITLEMENTS"
    assert body =~ ~s("$identity" != "-")
    assert body =~ "Authority=Developer ID Application:"
  end

  test "package test and verify scripts gate Developer ID and notarization" do
    test_body = File.read!(@test_package)
    verify_body = File.read!(@verify)

    assert test_body =~ "--require-developer-id"
    assert test_body =~ "--require-notarized"
    assert test_body =~ "verify-macos-desktop-release.sh"

    assert verify_body =~ "--require-developer-id"
    assert verify_body =~ "--require-notarized"
    assert verify_body =~ "--require-hardened-runtime"
    assert verify_body =~ "spctl --assess"
    assert verify_body =~ "stapler validate"
  end

  test "notarize script supports dry-run and never embeds real credentials" do
    body = File.read!(@notarize)
    assert body =~ "CASEIN_NOTARY_DRY_RUN"
    assert body =~ "CASEIN_NOTARY_KEYCHAIN_PROFILE"
    assert body =~ "notarytool submit"
    assert body =~ "stapler staple"
    refute body =~ "-----BEGIN"
    refute body =~ ~r/app-specific-password-[A-Za-z0-9]/
    refute body =~ ~r/AuthKey_[A-Z0-9]+\.p8/
  end

  test "notarize dry-run succeeds offline without credentials" do
    assert {output, 0} =
             System.cmd("bash", [@notarize, "does-not-need-to-exist.zip"],
               env: [{"CASEIN_NOTARY_DRY_RUN", "1"}],
               stderr_to_stdout: true
             )

    assert output =~ "DRY RUN"
    assert output =~ "notarytool submit"
  end

  test "evidence collector writes schema-1 JSON off Darwin as blocked host stub" do
    tmp =
      Path.join(System.tmp_dir!(), "casein-macos-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    out = Path.join(tmp, "evidence.json")
    on_exit(fn -> File.rm_rf(tmp) end)

    assert {output, 0} =
             System.cmd(
               "bash",
               [
                 @collect,
                 "--app",
                 Path.join(tmp, "missing.app"),
                 "--out",
                 out
               ],
               stderr_to_stdout: true
             )

    assert output =~ "Wrote macOS desktop evidence"
    assert File.exists?(out)

    evidence = out |> File.read!() |> Jason.decode!()
    assert evidence["schema"] == 1
    assert evidence["kind"] == "macos_desktop_release_evidence"
    assert evidence["issue"] == 382
    assert evidence["result"] in ["blocked", "failed"]
    assert is_list(evidence["missing"])
    assert "developer_id" in evidence["missing"]
    assert "notary_profile" in evidence["missing"]
    assert "signed_lifecycle" in evidence["missing"]
    assert evidence["claims"]["passed_release"] == false
    assert evidence["claims"]["developer_id"] == false
    assert is_map(evidence["git"])
    assert is_map(evidence["host"])
    assert is_map(evidence["app"])
    assert is_map(evidence["archive"])
    assert is_list(evidence["phases"])
    assert is_list(evidence["notes"])

    encoded = File.read!(out)
    refute encoded =~ "BEGIN CERTIFICATE"
    refute encoded =~ "PRIVATE KEY"
    refute encoded =~ "CASEIN_NOTARY_APP_PASSWORD"

    assert {validate_out, 0} =
             System.cmd("bash", [@validate, out], stderr_to_stdout: true)

    assert validate_out =~ "VALID:"
    assert validate_out =~ "NEED (human): developer_id"
  end

  test "dry-run evidence is incomplete with canonical missing[] and never claims success" do
    tmp =
      Path.join(System.tmp_dir!(), "casein-macos-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    out = Path.join(tmp, "dry-run.evidence.json")
    on_exit(fn -> File.rm_rf(tmp) end)

    assert {output, 0} =
             System.cmd(
               "bash",
               [@collect, "--dry-run", "--out", out],
               stderr_to_stdout: true
             )

    assert output =~ "Wrote macOS desktop evidence"
    assert output =~ "result=incomplete"
    assert output =~ "NEED (human): developer_id"
    assert output =~ "NEED (human): notary_profile"
    assert output =~ "NEED (human): signed_lifecycle"

    evidence = out |> File.read!() |> Jason.decode!()
    assert evidence["result"] == "incomplete"
    assert evidence["missing"] == @canonical_missing

    assert evidence["claims"] == %{
             "developer_id" => false,
             "notarized" => false,
             "stapled" => false,
             "signed_lifecycle" => false,
             "passed_release" => false
           }

    assert "dry_run" in evidence["phases"]
    refute evidence["result"] == "passed_release"

    assert {validate_out, 0} =
             System.cmd("bash", [@validate, "--print-needs", out], stderr_to_stdout: true)

    assert validate_out =~ "VALID:"
    assert validate_out =~ "missing="
    assert validate_out =~ "developer_id"
    assert validate_out =~ "notary_profile"
    assert validate_out =~ "signed_lifecycle"
    assert validate_out =~ "NEED (human): developer_id"
    assert validate_out =~ "Operator steps:"
    assert validate_out =~ "Unblocks when:"
  end

  test "validator rejects silent incomplete evidence and overclaimed passed_release" do
    tmp =
      Path.join(System.tmp_dir!(), "casein-macos-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    silent = Path.join(tmp, "silent.json")

    File.write!(
      silent,
      Jason.encode!(%{
        "schema" => 1,
        "kind" => "macos_desktop_release_evidence",
        "issue" => 382,
        "started_at_utc" => "2026-08-10T00:00:00Z",
        "completed_at_utc" => "2026-08-10T00:00:01Z",
        "result" => "incomplete",
        "error" => "",
        "git" => %{"revision" => "abc", "describe" => "abc"},
        "host" => %{"os" => "Linux", "arch" => "x86_64"},
        "app" => %{
          "path" => "/tmp/x.app",
          "exists" => false,
          "signature_kind" => "missing",
          "signer_authority" => "",
          "team_identifier" => "",
          "hardened_runtime" => false,
          "codesign_verify" => "skipped",
          "spctl" => "skipped",
          "stapler" => "skipped"
        },
        "archive" => %{"path" => "", "exists" => false, "sha256" => "", "bytes" => 0},
        "phases" => [],
        "notes" => []
      })
    )

    assert {_, 2} = System.cmd("bash", [@validate, silent], stderr_to_stdout: true)

    overclaim = Path.join(tmp, "overclaim.json")

    File.write!(
      overclaim,
      Jason.encode!(%{
        "schema" => 1,
        "kind" => "macos_desktop_release_evidence",
        "issue" => 382,
        "started_at_utc" => "2026-08-10T00:00:00Z",
        "completed_at_utc" => "2026-08-10T00:00:01Z",
        "result" => "passed_release",
        "error" => "",
        "missing" => [],
        "claims" => %{"passed_release" => true, "developer_id" => true},
        "git" => %{"revision" => "abc", "describe" => "abc"},
        "host" => %{"os" => "Darwin", "arch" => "arm64"},
        "app" => %{
          "path" => "/tmp/x.app",
          "exists" => true,
          "signature_kind" => "adhoc",
          "signer_authority" => "",
          "team_identifier" => "",
          "hardened_runtime" => false,
          "codesign_verify" => "passed",
          "spctl" => "skipped",
          "stapler" => "skipped"
        },
        "archive" => %{"path" => "", "exists" => false, "sha256" => "", "bytes" => 0},
        "phases" => [],
        "notes" => []
      })
    )

    assert {out, 2} = System.cmd("bash", [@validate, overclaim], stderr_to_stdout: true)
    assert out =~ "INVALID:"
    assert out =~ "developer_id"
  end

  test "macos-desktop workflow keeps 7-day artifact retention and evidence paths" do
    body = File.read!(@workflow)
    assert body =~ "retention-days: 7"
    assert body =~ "collect-macos-desktop-evidence.sh"
    assert body =~ "verify-macos-desktop-release.sh"
    assert body =~ "artifact storage quota"
    # Must not claim production notarization in the ad-hoc smoke job.
    refute body =~ "notarytool submit"
  end

  test "operator runbook exists and forbids secret commits" do
    assert File.exists?(@runbook)
    body = File.read!(@runbook)
    assert body =~ "#382"
    assert body =~ "Developer ID"
    assert body =~ "notarize"
    assert body =~ "Never commit"
    assert body =~ "upload-artifact"
    assert body =~ "CASEIN_REQUIRE_DEVELOPER_ID"
    assert body =~ "validate-macos-desktop-evidence.sh"
    assert body =~ "--dry-run"
    assert body =~ "missing"
    assert body =~ "--print-template"
    assert body =~ "--fixture-dir"
    assert body =~ "macos_desktop_release_evidence.schema.json"
  end

  test "validator check-schema, print-template, and print-operator-steps" do
    assert {out, 0} = System.cmd("bash", [@validate, "--check-schema"], stderr_to_stdout: true)
    assert out =~ "SCHEMA_OK"

    assert {template, 0} =
             System.cmd("bash", [@validate, "--print-template"], stderr_to_stdout: true)

    doc = Jason.decode!(template)
    assert doc["result"] == "incomplete"
    assert doc["missing"] == @canonical_missing
    assert doc["claims"]["passed_release"] == false
    assert is_map(doc["staging"])
    assert is_map(doc["fixture_refs"])

    assert {steps, 0} =
             System.cmd("bash", [@validate, "--print-operator-steps"], stderr_to_stdout: true)

    assert steps =~ "NEED (human): Apple notarize credentials"
    assert steps =~ "Developer ID"
    assert steps =~ "notarytool store-credentials"
    assert steps =~ "CASEIN_LIFECYCLE_ATTESTED=1"
    assert steps =~ "stage-macos-desktop-artifacts.sh"
    refute steps =~ "BEGIN CERTIFICATE"
    refute steps =~ ~r/password\s*=\s*['\"][^'\"]{8,}/i
  end

  test "checked-in fixtures: dry-run accepts, silent and overclaim reject" do
    dry = Path.join(@fixtures, "incomplete_dry_run.json")
    silent = Path.join(@fixtures, "silent_incomplete_no_missing.json")
    overclaim = Path.join(@fixtures, "overclaim_adhoc_passed_release.json")

    assert {out, 0} = System.cmd("bash", [@validate, dry], stderr_to_stdout: true)
    assert out =~ "VALID:"
    assert out =~ "incomplete"

    assert {_, 2} = System.cmd("bash", [@validate, silent], stderr_to_stdout: true)

    assert {rej, 2} = System.cmd("bash", [@validate, overclaim], stderr_to_stdout: true)
    assert rej =~ "INVALID:"
  end

  test "fixture-dir backs signed_lifecycle claim only when file present" do
    tmp =
      Path.join(System.tmp_dir!(), "casein-macos-fix-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)

    evidence = Path.join(tmp, "evidence.json")

    base = %{
      "schema" => 1,
      "kind" => "macos_desktop_release_evidence",
      "issue" => 382,
      "started_at_utc" => "2026-08-10T00:00:00Z",
      "completed_at_utc" => "2026-08-10T00:00:01Z",
      "result" => "incomplete",
      "error" => "",
      "missing" => ["developer_id", "notary_profile"],
      "claims" => %{
        "developer_id" => false,
        "notarized" => false,
        "stapled" => false,
        "signed_lifecycle" => true,
        "passed_release" => false
      },
      "fixture_refs" => %{"signed_lifecycle" => "lifecycle_notes"},
      "git" => %{"revision" => "abc", "describe" => "abc"},
      "host" => %{"os" => "Linux", "arch" => "x86_64"},
      "app" => %{
        "path" => "/tmp/x.app",
        "exists" => false,
        "signature_kind" => "missing",
        "signer_authority" => "",
        "team_identifier" => "",
        "hardened_runtime" => false,
        "codesign_verify" => "skipped",
        "spctl" => "skipped",
        "stapler" => "skipped"
      },
      "archive" => %{"path" => "", "exists" => false, "sha256" => "", "bytes" => 0},
      "phases" => [],
      "notes" => ["fixture test"]
    }

    File.write!(evidence, Jason.encode!(base))

    # No fixture dir → reject lifecycle claim on incomplete/Linux host.
    assert {_, 2} = System.cmd("bash", [@validate, evidence], stderr_to_stdout: true)

    empty_dir = Path.join(tmp, "empty")
    File.mkdir_p!(empty_dir)

    assert {_, 2} =
             System.cmd(
               "bash",
               [@validate, "--fixture-dir", empty_dir, evidence],
               stderr_to_stdout: true
             )

    op_dir = Path.join(@fixtures, "operator")

    assert {out, 0} =
             System.cmd(
               "bash",
               [@validate, "--fixture-dir", op_dir, evidence],
               stderr_to_stdout: true
             )

    assert out =~ "VALID:"
    assert out =~ "fixture_dir="
  end

  test "collect dry-run embeds staging receipt summary without claiming upload=release" do
    tmp =
      Path.join(System.tmp_dir!(), "casein-macos-evidence-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    out = Path.join(tmp, "dry.evidence.json")
    receipt = Path.join(tmp, "upload-receipt.json")
    on_exit(fn -> File.rm_rf(tmp) end)

    File.write!(
      receipt,
      Jason.encode!(%{
        "mode" => "skip",
        "upload_attempted" => false,
        "upload_succeeded" => false,
        "label" => "Casein-macos-fixture"
      })
    )

    assert {_, 0} =
             System.cmd(
               "bash",
               [@collect, "--dry-run", "--out", out, "--staging-receipt", receipt],
               stderr_to_stdout: true
             )

    evidence = out |> File.read!() |> Jason.decode!()
    assert evidence["result"] == "incomplete"
    assert evidence["missing"] == @canonical_missing
    assert evidence["staging"]["receipt_mode"] == "skip"
    assert evidence["staging"]["upload_attempted"] == false
    assert evidence["staging"]["upload_succeeded"] == false
    assert evidence["staging"]["receipt_path"] =~ "upload-receipt.json"
    assert is_map(evidence["fixture_refs"])
    assert evidence["claims"]["passed_release"] == false

    assert {_, 0} = System.cmd("bash", [@validate, out], stderr_to_stdout: true)
  end

  defp executable?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{mode: mode}} ->
        # Owner/group/other execute bit
        Bitwise.band(mode, 0o111) != 0

      _ ->
        false
    end
  end
end
