defmodule CaseinMob.IOSFeedLifecycleHarnessContractTest do
  use ExUnit.Case, async: true

  @harness Path.expand(
             "../../ios/CaseinMobSoakUITests/CaseinMobFeedLifecycleUITests.swift",
             __DIR__
           )
  @project Path.expand("../../ios/Provision.xcodeproj/project.pbxproj", __DIR__)
  @legacy_scheme Path.expand(
                   "../../ios/Provision.xcodeproj/xcshareddata/xcschemes/CaseinMobSoakUITests.xcscheme",
                   __DIR__
                 )
  @lifecycle_scheme Path.expand(
                      "../../ios/Provision.xcodeproj/xcshareddata/xcschemes/CaseinMobFeedLifecycleUITests.xcscheme",
                      __DIR__
                    )
  @test_plan Path.expand("../../ios/CaseinMobFeedLifecycleSoak.xctestplan", __DIR__)
  @runner Path.expand("../../ios/run_feed_lifecycle_soak.sh", __DIR__)

  @exact_test_identifier "CaseinMobFeedLifecycleUITests/CaseinMobFeedLifecycleUITests/testCanonicalDevboxReconnectWithoutRelaunch"

  test "signed lifecycle harness is one bounded reconnect against the running canonical app" do
    harness = File.read!(@harness)
    project = File.read!(@project)
    legacy_scheme = File.read!(@legacy_scheme)
    lifecycle_scheme = File.read!(@lifecycle_scheme)
    runner = File.read!(@runner)
    test_plan = @test_plan |> File.read!() |> Jason.decode!()

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

    assert_before(harness, "selectedDevbox.tap()", "let transition = XCTNSPredicateExpectation(")

    assert_before(
      harness,
      "let transition = XCTNSPredicateExpectation(",
      "authenticatedFeed.waitForExistence(timeout: 30)"
    )

    assert_before(
      harness,
      "authenticatedFeed.waitForExistence(timeout: 30)",
      "canonicalOrigin.waitForExistence(timeout: 10)"
    )

    assert_before(
      harness,
      "canonicalOrigin.waitForExistence(timeout: 10)",
      "selectedDevbox.waitForExistence(timeout: 10)"
    )

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

    assert project =~ "CC000006 /* CaseinMobFeedLifecycleUITests */"

    assert project =~
             "PRODUCT_BUNDLE_IDENTIFIER = com.alexandrefamilyfarm.casein-mob.feed-lifecycle-ui-tests;"

    assert source_files_for(project, "BB000008") == [
             "BB000001 /* CaseinMobSoakUITests.swift in Sources */"
           ]

    assert source_files_for(project, "CC000008") == [
             "CC000001 /* CaseinMobFeedLifecycleUITests.swift in Sources */"
           ]

    assert legacy_scheme =~ ~s(BlueprintIdentifier = "BB000006")
    refute legacy_scheme =~ "CaseinMobFeedLifecycleUITests"

    assert lifecycle_scheme =~ ~s(BlueprintIdentifier = "CC000006")
    assert lifecycle_scheme =~ ~s(BuildableName = "CaseinMobFeedLifecycleUITests.xctest")
    assert lifecycle_scheme =~ ~s(BlueprintName = "CaseinMobFeedLifecycleUITests")
    assert lifecycle_scheme =~ ~s(shouldAutocreateTestPlan = "NO")
    assert lifecycle_scheme =~ ~s(codeCoverageEnabled = "NO")

    assert lifecycle_scheme =~
             ~s(reference = "container:CaseinMobFeedLifecycleSoak.xctestplan" default = "YES")

    assert occurrences(lifecycle_scheme, "<TestPlanReference") == 1
    refute lifecycle_scheme =~ "<TestableReference"

    assert test_plan["testTargets"] == [
             %{
               "parallelizable" => false,
               "selectedTests" => [
                 "CaseinMobFeedLifecycleUITests/testCanonicalDevboxReconnectWithoutRelaunch"
               ],
               "target" => %{
                 "containerPath" => "container:Provision.xcodeproj",
                 "identifier" => "CC000006",
                 "name" => "CaseinMobFeedLifecycleUITests"
               }
             }
           ]

    assert test_plan["defaultOptions"] == %{
             "areLocalizationScreenshotsEnabled" => false,
             "codeCoverage" => false,
             "diagnosticCollectionPolicy" => "Never",
             "preferredScreenCaptureFormat" => "screenshots",
             "uiTestingScreenshotsLifetime" => "keepNever",
             "userAttachmentLifetime" => "keepNever"
           }

    assert occurrences(runner, "xcodebuild test") == 1
    assert runner =~ "-scheme CaseinMobFeedLifecycleUITests"
    assert runner =~ "-testPlan CaseinMobFeedLifecycleSoak"
    assert runner =~ "-only-testing:#{@exact_test_identifier}"
    assert runner =~ "-test-iterations 20"
    assert runner =~ "-test-repetition-relaunch-enabled NO"
    assert runner =~ "-collect-test-diagnostics never"
    assert runner =~ "-enablePerformanceTestsDiagnostics NO"
    assert runner =~ "-enableCodeCoverage NO"
    assert runner =~ "CODE_SIGNING_ALLOWED=YES"
    assert runner =~ "CODE_SIGNING_REQUIRED=YES"
    assert runner =~ ">/dev/null 2>&1"
    assert runner =~ "trap cleanup EXIT"
    assert runner =~ "trap 'exit 74' HUP INT TERM"
    assert runner =~ ~s(-derivedDataPath "${artifact_root}/DerivedData")
    assert runner =~ ~s(-resultBundlePath "${artifact_root}/Result.xcresult")

    for forbidden <- [
          "-resultStreamPath",
          "tee ",
          "xcresulttool",
          "screenrecord",
          "XCTAttachment"
        ] do
      refute runner =~ forbidden, "forbidden retained runner surface: #{forbidden}"
    end

    assert Bitwise.band(File.stat!(@runner).mode, 0o111) == 0o111
  end

  defp source_files_for(project, phase_id) do
    [_, body] =
      Regex.run(
        ~r/#{phase_id} \/\* Sources \*\/ = \{.*?files = \((.*?)\);/s,
        project
      )

    body
    |> String.split("\n", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.trim_trailing(&1, ","))
  end

  defp assert_before(text, first, second) do
    {first_offset, _length} = :binary.match(text, first)
    {second_offset, _length} = :binary.match(text, second)
    assert first_offset < second_offset, "expected #{inspect(first)} before #{inspect(second)}"
  end

  defp occurrences(text, fragment) do
    text
    |> String.split(fragment)
    |> length()
    |> Kernel.-(1)
  end
end
