defmodule CaseinMob.IOSFeedLifecycleHarnessContractTest do
  use ExUnit.Case, async: true

  @harness Path.expand(
             "../../ios/CaseinMobSoakUITests/CaseinMobFeedLifecycleUITests.swift",
             __DIR__
           )
  @project Path.expand("../../ios/Provision.xcodeproj/project.pbxproj", __DIR__)
  @scheme Path.expand(
            "../../ios/Provision.xcodeproj/xcshareddata/xcschemes/CaseinMobSoakUITests.xcscheme",
            __DIR__
          )

  test "signed lifecycle harness is one bounded reconnect against the running canonical app" do
    harness = File.read!(@harness)
    project = File.read!(@project)
    scheme = File.read!(@scheme)

    assert Regex.scan(~r/\bfunc test[A-Za-z0-9_]+\(\) throws/, harness) == [
             ["func testCanonicalDevboxReconnectWithoutRelaunch() throws"]
           ]

    assert harness =~
             ~s(bundleIdentifier: "com.alexandrefamilyfarm.casein-mob")

    assert harness =~ ~s(app.buttons["Selected · Devbox"])
    assert harness =~ ~s(app.staticTexts["https://casein.devbox.milcgroup.com"])
    assert harness =~ ~s(app.staticTexts["Authenticated live feed"])
    assert harness =~ ~s(app.staticTexts["Saved profile · validating live access"])
    assert harness =~ ~s(app.staticTexts["Devbox · Connecting"])
    assert occurrences(harness, "selectedDevbox.tap()") == 1
    assert occurrences(harness, "app.activate()") == 1

    assert harness =~ "timeout: 10"
    assert harness =~ "timeout: 15"
    assert harness =~ "timeout: 30"
    refute Regex.match?(~r/timeout:\s*[^\d\s]/, harness)

    for forbidden <- [
          "app.launch(",
          "app.terminate(",
          "launchArguments",
          "launchEnvironment",
          "Pair workspace",
          "+ Pair",
          "Unpair",
          "Approve",
          "Request changes",
          "Acknowledge",
          "Open full terminal",
          "URLSession",
          "NWPathMonitor",
          "XCUIDevice.shared",
          "screenshot(",
          "XCTAttachment",
          "add(",
          "print(",
          "os_log",
          "Logger"
        ] do
      refute harness =~ forbidden, "forbidden lifecycle harness surface: #{forbidden}"
    end

    assert project =~
             "CC000001 /* CaseinMobFeedLifecycleUITests.swift in Sources */"

    assert project =~
             "CC000002 /* CaseinMobFeedLifecycleUITests.swift */"

    assert project =~
             "PRODUCT_BUNDLE_IDENTIFIER = com.alexandrefamilyfarm.casein-mob.soak-ui-tests;"

    assert scheme =~ ~s(BlueprintIdentifier = "BB000006")
    assert scheme =~ ~s(BuildableName = "CaseinMobSoakUITests.xctest")
    assert scheme =~ ~s(BlueprintName = "CaseinMobSoakUITests")
    assert occurrences(scheme, "<TestableReference") == 1
  end

  defp occurrences(text, fragment) do
    text
    |> String.split(fragment)
    |> length()
    |> Kernel.-(1)
  end
end
