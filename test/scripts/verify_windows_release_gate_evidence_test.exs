defmodule Scripts.VerifyWindowsReleaseGateEvidenceTest do
  @moduledoc """
  Hermetic guards for the #376 Windows release-gate evidence dry-run.

  Never talks to Windows, Authenticode, or a clean VM. Pins: dry-run keeps
  production_signed/real_reboot/clean_machine_no_tooling false, validator
  rejects true strong claims without operator fixture files, and docs name
  package-windows-desktop.ps1 -RequireSigned plus clean Win11 steps.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify_windows_release_gate_evidence.sh", __DIR__)
  @schema Path.expand(
            "../../scripts/schemas/windows_release_gate_evidence.schema.json",
            __DIR__
          )
  @gate_doc Path.expand("../../docs/desktop/windows_release_gate_evidence.md", __DIR__)
  @acceptance Path.expand("../../docs/desktop/windows_mobile_acceptance.md", __DIR__)
  @gap Path.expand("../../docs/desktop/windows_acceptance_gap_audit.md", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "casein-376-gate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "script and schema exist; script has valid shell syntax" do
    assert File.exists?(@script)
    assert File.exists?(@schema)
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "help names issue 376 and refuses release-gate completion claim" do
    {out, status} = System.cmd("bash", [@script, "--help"], stderr_to_stdout: true)
    assert status == 0
    assert out =~ "376"
    assert out =~ "dry-run"
    assert out =~ "validate-evidence"
    assert out =~ "not release-gate completion"
  end

  test "schema pins issue 376 and strong claim keys" do
    schema = Jason.decode!(File.read!(@schema))
    assert schema["properties"]["schema"]["const"] == "casein_windows_release_gate"
    assert schema["properties"]["issue"]["const"] == 376
    assert schema["additionalProperties"] == false

    claims = schema["properties"]["claims"]["required"]
    assert "production_signed" in claims
    assert "real_reboot" in claims
    assert "clean_machine_no_tooling" in claims
    assert "linux_devbox_run" in claims
  end

  test "runbook declares honesty and operator RequireSigned path" do
    doc = File.read!(@gate_doc)
    assert doc =~ "#376"
    assert doc =~ "gate_unreachable_on_this_host"
    assert doc =~ "What this box can and cannot prove"
    assert doc =~ "package-windows-desktop.ps1"
    assert doc =~ "-RequireSigned"
    assert doc =~ "Test-CaseinCleanMachine"
    assert doc =~ "Test-CaseinRebootPersistence"
    assert doc =~ "fixture"
    refute doc =~ "BEGIN RSA PRIVATE KEY"
  end

  test "acceptance and gap docs point at the release-gate evidence contract" do
    acceptance = File.read!(@acceptance)
    gap = File.read!(@gap)

    assert acceptance =~ "verify_windows_release_gate_evidence"
    assert acceptance =~ "windows_release_gate_evidence"
    assert gap =~ "verify_windows_release_gate_evidence"
    assert gap =~ "windows_release_gate_evidence"
  end

  test "print-operator-steps names RequireSigned and clean Win11 reboot" do
    {out, status} =
      System.cmd("bash", [@script, "--print-operator-steps"], stderr_to_stdout: true)

    assert status == 0
    assert out =~ "NEED (human):"
    assert out =~ "-RequireSigned"
    assert out =~ "Test-CaseinCleanMachine"
    assert out =~ "Test-CaseinRebootPersistence"
    assert out =~ "real_reboot"
  end

  test "dry-run writes gate_unreachable and never sets strong claims", %{tmp: tmp} do
    evidence = Path.join(tmp, "self.json")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--dry-run", "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "gate_unreachable_on_this_host"

    doc = Jason.decode!(File.read!(evidence))
    assert doc["verdict"] == "gate_unreachable_on_this_host"
    assert doc["issue"] == 376
    assert doc["claims"]["production_signed"] == false
    assert doc["claims"]["real_reboot"] == false
    assert doc["claims"]["clean_machine_no_tooling"] == false
    assert doc["claims"]["linux_devbox_run"] == true
    assert doc["claims"]["secrets_redacted"] == true
  end

  test "print-template is gate_incomplete with strong claims false" do
    {out, status} = System.cmd("bash", [@script, "--print-template"], stderr_to_stdout: true)
    assert status == 0
    doc = Jason.decode!(out)
    assert doc["verdict"] == "gate_incomplete"
    assert doc["claims"]["production_signed"] == false
    assert doc["claims"]["real_reboot"] == false
    assert doc["claims"]["clean_machine_no_tooling"] == false
    assert is_list(doc["operator_commands"])
    assert Enum.any?(doc["operator_commands"], &String.contains?(&1, "RequireSigned"))
  end

  test "validate-evidence accepts dry-run output", %{tmp: tmp} do
    evidence = Path.join(tmp, "self.json")

    {_, 0} =
      System.cmd("bash", [@script, "--dry-run", "--evidence", evidence], stderr_to_stdout: true)

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", evidence], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "gate_unreachable_on_this_host"
  end

  test "validate-evidence rejects real_reboot=true without fixture file", %{tmp: tmp} do
    path = Path.join(tmp, "fake-reboot.json")

    doc =
      base_doc()
      |> put_in(["claims", "real_reboot"], true)
      |> put_in(["fixture_refs", "real_reboot"], "real_reboot.json")

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
    assert out =~ "fixture" or out =~ "ERROR"
  end

  test "validate-evidence rejects production_signed=true without fixture file", %{tmp: tmp} do
    path = Path.join(tmp, "fake-sign.json")

    doc =
      base_doc()
      |> put_in(["claims", "production_signed"], true)
      |> put_in(["fixture_refs", "production_sign"], "production_sign.json")

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
  end

  test "validate-evidence rejects linux_devbox_run with strong claim", %{tmp: tmp} do
    path = Path.join(tmp, "devbox-lie.json")

    doc =
      base_doc()
      |> put_in(["claims", "linux_devbox_run"], true)
      |> put_in(["claims", "production_signed"], true)
      |> put_in(["verdict"], "gate_incomplete")

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
  end

  test "validate-evidence accepts release_gate_passed only with honest fixtures", %{tmp: tmp} do
    fixtures = Path.join(tmp, "fixtures")
    File.mkdir_p!(fixtures)

    File.write!(
      Path.join(fixtures, "production_sign.json"),
      Jason.encode!(%{
        "signer_subject" => "CN=Example Code Signing (NOT REAL)",
        "signer_thumbprint" => "0123456789ABCDEF0123456789ABCDEF01234567",
        "require_signed" => true,
        "signed_files" => [%{"path" => "Casein.exe", "sha256" => String.duplicate("a", 64)}]
      })
    )

    File.write!(
      Path.join(fixtures, "clean_machine.json"),
      Jason.encode!(%{
        "claims" => %{
          "clean_machine_no_tooling" => true,
          "real_reboot" => false
        }
      })
    )

    File.write!(
      Path.join(fixtures, "real_reboot.json"),
      Jason.encode!(%{
        "claims" => %{"real_reboot" => true},
        "boot_stamp_before" => "2026-08-01T00:00:00Z",
        "boot_stamp_after" => "2026-08-01T00:05:00Z"
      })
    )

    path = Path.join(tmp, "pass.json")
    File.write!(path, Jason.encode!(release_gate_passed_doc()))

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--validate-evidence", path, "--fixture-dir", fixtures],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "release_gate_passed"
  end

  test "validate-evidence rejects release_gate_passed when reboot fixture is self-test", %{
    tmp: tmp
  } do
    fixtures = Path.join(tmp, "fixtures")
    File.mkdir_p!(fixtures)

    File.write!(
      Path.join(fixtures, "production_sign.json"),
      Jason.encode!(%{
        "signer_subject" => "CN=Example Code Signing (NOT REAL)",
        "signer_thumbprint" => "0123456789ABCDEF0123456789ABCDEF01234567",
        "require_signed" => true,
        "signed_files" => [%{"path" => "Casein.exe", "sha256" => String.duplicate("b", 64)}]
      })
    )

    File.write!(
      Path.join(fixtures, "clean_machine.json"),
      Jason.encode!(%{"claims" => %{"clean_machine_no_tooling" => true, "real_reboot" => false}})
    )

    File.write!(
      Path.join(fixtures, "real_reboot.json"),
      Jason.encode!(%{
        "claims" => %{"real_reboot" => true},
        "self_test_continuation" => true
      })
    )

    path = Path.join(tmp, "selftest-lie.json")
    File.write!(path, Jason.encode!(release_gate_passed_doc()))

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--validate-evidence", path, "--fixture-dir", fixtures],
        stderr_to_stdout: true
      )

    assert status == 3, out
  end

  test "validate-evidence rejects secret-like private key text", %{tmp: tmp} do
    path = Path.join(tmp, "secret.json")

    doc =
      base_doc()
      |> put_in(["host_probe", "notes"], "BEGIN RSA PRIVATE KEY-----fake")

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
  end

  test "script never pretends production Authenticode or clean-machine pass" do
    content = File.read!(@script)
    assert content =~ "NEVER pretends"
    assert content =~ "production_signed\": False"
    assert content =~ "real_reboot\": False"
    assert content =~ "clean_machine_no_tooling\": False"
    assert content =~ "gate_unreachable_on_this_host"
    assert content =~ "-RequireSigned"
    refute content =~ "signtool sign"
    refute content =~ "Invoke-Pester"
  end

  defp base_doc do
    %{
      "schema" => "casein_windows_release_gate",
      "schema_version" => 1,
      "issue" => 376,
      "recorded_at_utc" => "2026-08-10T12:00:00Z",
      "product_revision" => String.duplicate("a", 40),
      "operator" => "test",
      "claims" => %{
        "production_signed" => false,
        "real_reboot" => false,
        "clean_machine_no_tooling" => false,
        "linux_devbox_run" => false,
        "secrets_redacted" => true
      },
      "host_probe" => %{
        "uname" => "Windows_NT",
        "is_windows" => true,
        "signtool_present" => true,
        "notes" => "test"
      },
      "fixture_refs" => %{},
      "operator_commands" => [],
      "attachments" => %{"log_refs" => [], "issue_comment_urls" => []},
      "verdict" => "gate_incomplete"
    }
  end

  defp release_gate_passed_doc do
    base_doc()
    |> Map.put("verdict", "release_gate_passed")
    |> put_in(["claims", "production_signed"], true)
    |> put_in(["claims", "real_reboot"], true)
    |> put_in(["claims", "clean_machine_no_tooling"], true)
    |> put_in(["claims", "linux_devbox_run"], false)
    |> Map.put("fixture_refs", %{
      "production_sign" => "production_sign.json",
      "clean_machine" => "clean_machine.json",
      "real_reboot" => "real_reboot.json"
    })
  end
end
