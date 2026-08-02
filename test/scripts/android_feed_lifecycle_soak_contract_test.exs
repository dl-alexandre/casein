defmodule Scripts.AndroidFeedLifecycleSoakContractTest do
  use ExUnit.Case, async: true

  @root Path.expand("../..", __DIR__)
  @driver_path Path.join([
                 @root,
                 "native/casein_mob/android/app/src/androidTest/java/com/example/casein_mob",
                 "CaseinFeedLifecycleSoakTest.kt"
               ])

  test "signed reconnect driver is exact, bounded, and app-scoped" do
    source = File.read!(@driver_path)

    assert length(Regex.scan(~r/^\s*@Test\s*$/m, source)) == 1
    assert source =~ "fun twentyExplicitCurrentOriginReconnects()"
    assert source =~ "const val RECONNECT_CYCLES = 20"

    assert source =~
             ~r/repeat\(RECONNECT_CYCLES\)\s*\{\s*runOneExplicitReconnect\(\)\s*\}/

    assert source =~
             ~r/private fun runOneExplicitReconnect\(\)\s*\{.*?selectedOrigin\.click\(\).*?Until\.hasObject\(CONNECTING_STATUS\).*?waitForText\(AUTHENTICATED_FEED, RECOVERY_TIMEOUT_MS\).*?waitForText\(CANONICAL_ORIGIN\).*?hasText\(SELECTED_DEVBOX\).*?\n\s*\}/s

    assert source =~ ~s|ComponentName(PACKAGE_NAME, MAIN_ACTIVITY)|
    assert source =~ ~s|const val PACKAGE_NAME = "com.example.casein_mob"|
    assert source =~ ~s|const val MAIN_ACTIVITY = "com.example.casein_mob.MainActivity"|

    assert source =~
             ~s|const val CANONICAL_ORIGIN = "https://casein.devbox.milcgroup.com"|

    assert source =~ ~s|const val SELECTED_DEVBOX = "Selected · Devbox"|
    assert source =~ ~s|const val AUTHENTICATED_FEED = "Authenticated live feed"|
    assert source =~ "Saved profile · validating live access|Card stream connecting"
    assert source =~ "const val TRANSITION_TIMEOUT_MS = 12_000L"
    assert source =~ "const val RECOVERY_TIMEOUT_MS = 45_000L"

    assert source =~
             ~s|"casein_feed_lifecycle_soak result=pass reconnect_cycles=20"|

    assert length(Regex.scan(~r/\bLog\.[a-zA-Z]+\s*\(/, source)) == 1
    assert source =~ "Log.i(TAG, PASS_METADATA)"
  end

  test "signed reconnect driver contains no broad or mutating device controls" do
    source = File.read!(@driver_path)

    forbidden = [
      "executeShellCommand",
      "Runtime.getRuntime",
      "ProcessBuilder",
      "UiAutomation.executeShellCommand",
      "svc wifi",
      "settings put",
      "settings get",
      "airplane_mode",
      "pm clear",
      "pm uninstall",
      "force-stop",
      "casein://",
      "pressHome",
      "setOrientation",
      "+ Pair",
      "Pair workspace",
      "card_action",
      "Open full terminal",
      "takeScreenshot",
      "dumpWindowHierarchy",
      "wakeUp()",
      "sleep()",
      "pressKeyCode",
      "pressRecentApps"
    ]

    for fragment <- forbidden do
      refute source =~ fragment, "forbidden lifecycle-driver fragment: #{fragment}"
    end
  end
end
