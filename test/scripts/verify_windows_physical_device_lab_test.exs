defmodule Scripts.VerifyWindowsPhysicalDeviceLabTest do
  @moduledoc """
  Hermetic guards for the #377 physical Windows-origin device lab.

  Never talks to adb devices or claims a matrix pass. Pins: self-check keeps
  physical_* false, validator rejects secrets and dishonest matrix_passed, and
  the acceptance docs point operators at the lab runbook.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify_windows_physical_device_lab.sh", __DIR__)
  @schema Path.expand(
            "../../scripts/schemas/windows_physical_device_lab_evidence.schema.json",
            __DIR__
          )
  @lab_doc Path.expand("../../docs/desktop/windows_physical_device_lab.md", __DIR__)
  @acceptance Path.expand("../../docs/desktop/windows_mobile_acceptance.md", __DIR__)
  @gap Path.expand("../../docs/desktop/windows_acceptance_gap_audit.md", __DIR__)

  setup do
    tmp = Path.join(System.tmp_dir!(), "casein-377-lab-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp}
  end

  test "script and schema exist; script has valid shell syntax" do
    assert File.exists?(@script)
    assert File.exists?(@schema)
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "help names issue 377 and does not claim physical pass" do
    {out, status} = System.cmd("bash", [@script, "--help"], stderr_to_stdout: true)
    assert status == 0
    assert out =~ "377"
    assert out =~ "self-check"
    assert out =~ "validate-evidence"
    assert out =~ "not matrix completion"
  end

  test "schema pins fixed row ids and forbids additional properties" do
    schema = Jason.decode!(File.read!(@schema))
    assert schema["properties"]["schema"]["const"] == "casein_windows_physical_device_lab"
    assert schema["properties"]["issue"]["const"] == 377
    assert schema["additionalProperties"] == false

    rows = get_in(schema, ["$defs", "platform", "properties", "rows", "required"])
    assert "initial_pair" in rows
    assert "vpn_interface_change_repair" in rows
    assert "operator_verify_fail_closed" in rows
    assert length(rows) == 11
  end

  test "lab runbook declares reachability honesty and forbidden evidence" do
    doc = File.read!(@lab_doc)
    assert doc =~ "#377"
    assert doc =~ "lab_unreachable_on_this_host"
    assert doc =~ "What this box can and cannot prove"
    assert doc =~ "QR payloads"
    assert doc =~ "com.example.casein_mob"
    assert doc =~ "com.alexandrefamilyfarm.casein-mob"
    assert doc =~ "#376"
    assert doc =~ "#416"
    assert doc =~ "not** matrix completion" or doc =~ "not matrix completion"
  end

  test "acceptance and gap docs point at the lab runbook for #377" do
    acceptance = File.read!(@acceptance)
    gap = File.read!(@gap)

    assert acceptance =~ "windows_physical_device_lab"
    assert acceptance =~ "verify_windows_physical_device_lab"
    assert acceptance =~ "377"
    assert gap =~ "windows_physical_device_lab"
    assert gap =~ "377"
  end

  test "self-check writes lab_unreachable and never sets physical claims", %{tmp: tmp} do
    evidence = Path.join(tmp, "self.json")

    {out, status} =
      System.cmd(
        "bash",
        [@script, "--self-check", "--evidence", evidence],
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ "lab_unreachable_on_this_host"

    doc = Jason.decode!(File.read!(evidence))
    assert doc["verdict"] == "lab_unreachable_on_this_host"
    assert doc["issue"] == 377
    assert doc["claims"]["physical_android"] == false
    assert doc["claims"]["physical_ipad"] == false
    assert doc["claims"]["windows_origin_exercised"] == false
    assert doc["claims"]["simulator_or_emulator"] == false
    assert doc["host_probe"]["adb_present"] in [true, false]
    assert is_integer(doc["host_probe"]["adb_device_count"])
  end

  test "print-template is lab_incomplete with all rows not_run" do
    {out, status} = System.cmd("bash", [@script, "--print-template"], stderr_to_stdout: true)
    assert status == 0
    doc = Jason.decode!(out)
    assert doc["verdict"] == "lab_incomplete"
    assert doc["claims"]["physical_android"] == false

    for platform <- ["android", "ipad"] do
      rows = get_in(doc, ["platforms", platform, "rows"])
      assert map_size(rows) == 11
      assert Enum.all?(rows, fn {_k, v} -> v["outcome"] == "not_run" end)
    end
  end

  test "validate-evidence accepts self-check output", %{tmp: tmp} do
    evidence = Path.join(tmp, "self.json")

    {_, 0} =
      System.cmd("bash", [@script, "--self-check", "--evidence", evidence],
        stderr_to_stdout: true
      )

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", evidence], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "lab_unreachable_on_this_host"
  end

  test "validate-evidence rejects secret-like pairing token text", %{tmp: tmp} do
    path = Path.join(tmp, "secret.json")

    doc = base_doc()

    doc =
      put_in(doc, ["platforms", "android", "rows", "initial_pair", "notes"], "pairing_token=abc")

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
    assert out =~ "secret" or out =~ "ERROR"
  end

  test "validate-evidence rejects dishonest matrix_passed without physical rows", %{tmp: tmp} do
    path = Path.join(tmp, "fake-pass.json")

    doc =
      base_doc()
      |> Map.put("verdict", "matrix_passed")
      |> put_in(["claims", "physical_android"], true)
      |> put_in(["claims", "physical_ipad"], true)
      |> put_in(["claims", "windows_origin_exercised"], true)

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
  end

  test "validate-evidence accepts honest matrix_passed", %{tmp: tmp} do
    path = Path.join(tmp, "pass.json")
    File.write!(path, Jason.encode!(matrix_passed_doc()))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ "matrix_passed"
  end

  test "validate-evidence rejects matrix_passed with simulator claim", %{tmp: tmp} do
    path = Path.join(tmp, "sim.json")

    doc =
      matrix_passed_doc()
      |> put_in(["claims", "simulator_or_emulator"], true)

    File.write!(path, Jason.encode!(doc))

    {out, status} =
      System.cmd("bash", [@script, "--validate-evidence", path], stderr_to_stdout: true)

    assert status == 3, out
  end

  test "script never invokes a fake device matrix runner" do
    content = File.read!(@script)
    refute content =~ "xcrun simctl"
    refute content =~ "firebase test lab"
    refute content =~ "adb shell am instrument"
    assert content =~ "lab_unreachable_on_this_host"
    assert content =~ "physical_android"
    # self-check path must hard-code false physical claims
    assert content =~ "\"physical_android\": False"
    assert content =~ "NEVER pretends a physical matrix passed"
  end

  defp base_doc do
    row = %{"outcome" => "not_run", "notes" => ""}
    rows = Map.new(row_ids(), fn id -> {id, row} end)

    %{
      "schema" => "casein_windows_physical_device_lab",
      "schema_version" => 1,
      "issue" => 377,
      "recorded_at_utc" => "2026-08-09T12:00:00Z",
      "product_revision" => String.duplicate("a", 40),
      "operator" => "test",
      "claims" => %{
        "physical_android" => false,
        "physical_ipad" => false,
        "windows_origin_exercised" => false,
        "simulator_or_emulator" => false,
        "secrets_redacted" => true
      },
      "windows_host" => %{
        "os" => "Windows 11",
        "package_signed" => false,
        "origin_id_prefix" => "0123456789ab",
        "display_name_suffix_ok" => true,
        "trusted_lan" => "not_applicable",
        "profiles_collision_free" => false
      },
      "platforms" => %{
        "android" => %{
          "device_label" => "sm-t390",
          "os_version" => "9",
          "app_version" => "0.0.0",
          "rows" => rows
        },
        "ipad" => %{
          "device_label" => "coding-ipad",
          "os_version" => "18",
          "app_version" => "0.0.0",
          "rows" => rows
        }
      },
      "attachments" => %{
        "screenshot_count" => 0,
        "log_refs" => [],
        "issue_comment_urls" => []
      },
      "verdict" => "lab_incomplete"
    }
  end

  defp matrix_passed_doc do
    row = %{"outcome" => "passed", "at_utc" => "2026-08-09T12:00:00Z", "notes" => "ok"}
    rows = Map.new(row_ids(), fn id -> {id, row} end)

    base_doc()
    |> Map.put("verdict", "matrix_passed")
    |> put_in(["claims", "physical_android"], true)
    |> put_in(["claims", "physical_ipad"], true)
    |> put_in(["claims", "windows_origin_exercised"], true)
    |> put_in(["windows_host", "trusted_lan"], "private_rfc1918")
    |> put_in(["windows_host", "profiles_collision_free"], true)
    |> put_in(["windows_host", "package_signed"], true)
    |> put_in(["platforms", "android", "rows"], rows)
    |> put_in(["platforms", "ipad", "rows"], rows)
  end

  defp row_ids do
    [
      "initial_pair",
      "warm_resume_followup",
      "background_foreground",
      "killed_cold_cached",
      "host_restart",
      "device_restart",
      "offline_firewall_denied",
      "vpn_interface_change_repair",
      "tampered_target_fail_closed",
      "operator_verify_fail_closed",
      "pwa_escalation"
    ]
  end
end
