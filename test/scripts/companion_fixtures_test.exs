defmodule Scripts.CompanionFixturesTest do
  @moduledoc """
  Linux-safe lock for issue #416 companion **fixture** validation (slice2).

  Does not codesign or load real profiles. Fixtures are synthetic text plists.
  """
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/verify-companion-fixtures.sh", __DIR__)
  @mob Path.expand("../../native/casein_mob", __DIR__)
  @dev Path.join(@mob, "test/fixtures/ios_development_profile.plist")
  @dist Path.join(@mob, "test/fixtures/ios_distribution_profile.plist")

  test "fixture verifier has valid shell syntax" do
    assert {_, 0} = System.cmd("bash", ["-n", @script])
  end

  test "checked-in fixtures pass secret-free validation" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-fixtures-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(tmp) end)

    {output, status} =
      System.cmd("bash", [@script, "--json", tmp], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "fixture checks passed"
    refute output =~ "BEGIN CERTIFICATE"
    refute output =~ "BEGIN PRIVATE KEY"
    refute output =~ "-----BEGIN"

    evidence = tmp |> File.read!() |> Jason.decode!()
    assert evidence["schema"] == 1
    assert evidence["kind"] == "companion_fixtures"
    assert evidence["issue"] == 416
    assert evidence["passed"] == true
    assert evidence["checks"] >= 15
    assert evidence["claims"]["fixtures_obviously_fake"] == true
    assert evidence["claims"]["physical_device_install"] == false
    assert evidence["claims"]["real_signing_material"] == false
    assert evidence["claims"]["real_mobileprovision_present"] == false

    assert evidence["fixtures"]["development"] ==
             "native/casein_mob/test/fixtures/ios_development_profile.plist"
  end

  test "rejects a fixture dir that drops the fake label or adds PEM" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-bad-fixtures-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    # Copy structure then poison development fixture with PEM + strip fake label.
    File.cp!(@dev, Path.join(tmp_dir, "ios_development_profile.plist"))
    File.cp!(@dist, Path.join(tmp_dir, "ios_distribution_profile.plist"))

    poisoned = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0"><dict>
      <key>Entitlements</key>
      <dict>
        <key>aps-environment</key><string>development</string>
        <key>get-task-allow</key><true/>
        <key>application-identifier</key>
        <string>2MP8QWK7R6.com.alexandrefamilyfarm.casein-mob</string>
      </dict>
      <key>data</key>
      <string>-----BEGIN CERTIFICATE-----
    MIIFakeNotReal
    -----END CERTIFICATE-----</string>
    </dict></plist>
    """

    File.write!(Path.join(tmp_dir, "ios_development_profile.plist"), poisoned)

    {output, status} =
      System.cmd("bash", [@script, "--fixture-dir", tmp_dir], stderr_to_stdout: true)

    assert status != 0, output
    assert output =~ "FAIL" or output =~ "failed"
  end

  test "rejects distribution fixture that reintroduces get-task-allow" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "casein-companion-task-allow-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    File.cp!(@dev, Path.join(tmp_dir, "ios_development_profile.plist"))

    bad_dist =
      File.read!(@dist)
      |> String.replace(
        "</dict>\n</dict>\n</plist>",
        "    <key>get-task-allow</key>\n        <true/>\n    </dict>\n</dict>\n</plist>"
      )

    File.write!(Path.join(tmp_dir, "ios_distribution_profile.plist"), bad_dist)

    {output, status} =
      System.cmd("bash", [@script, "--fixture-dir", tmp_dir], stderr_to_stdout: true)

    assert status != 0, output
    assert output =~ "get-task-allow" or output =~ "FAIL"
  end

  test "fixtures themselves stay labeled fake and omit device/cert payload keys" do
    dev = File.read!(@dev)
    dist = File.read!(@dist)

    assert dev =~ "development"
    assert dist =~ "production"
    assert dist =~ "FAKE"
    refute dist =~ "get-task-allow"
    assert dev =~ "get-task-allow"
    refute dev =~ "ProvisionedDevices"
    refute dist =~ "DeveloperCertificates"
    refute dev =~ "BEGIN CERTIFICATE"
    refute dist =~ "BEGIN PRIVATE KEY"
  end
end
