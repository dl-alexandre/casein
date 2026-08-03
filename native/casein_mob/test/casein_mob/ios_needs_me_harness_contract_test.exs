defmodule CaseinMob.IOSNeedsMeHarnessContractTest do
  use ExUnit.Case, async: true

  @harness Path.expand(
             "../../ios/CaseinMobSoakUITests/CaseinMobSoakUITests.swift",
             __DIR__
           )

  test "physical direction proof uses the interactive open control for readiness" do
    harness = File.read!(@harness)

    assert harness =~ ~s(app.buttons["needs-me-open-sticky-direction"])
    assert harness =~ "openDirection.waitForExistence(timeout: 30)"
    assert harness =~ "Sticky pinning and"
    assert harness =~ "server/native render unit tests"
    refute harness =~ ~s(app.otherElements["needs-me-card-sticky-direction"])
    refute harness =~ ~s(app.otherElements["needs-me-card-non-sticky"])
  end
end
