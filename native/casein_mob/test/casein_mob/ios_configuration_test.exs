defmodule CaseinMob.IOSConfigurationTest do
  use ExUnit.Case, async: true

  @info_plist Path.expand("../../ios/Info.plist", __DIR__)
  @app_delegate Path.expand("../../ios/AppDelegate.m", __DIR__)
  @entitlements Path.expand("../../ios/CaseinMob.entitlements", __DIR__)
  @release_entitlements Path.expand("../../ios/CaseinMob.Release.entitlements", __DIR__)
  @xcode_project Path.expand("../../ios/Provision.xcodeproj/project.pbxproj", __DIR__)
  @development_profile Path.expand("../fixtures/ios_development_profile.plist", __DIR__)
  @distribution_profile Path.expand("../fixtures/ios_distribution_profile.plist", __DIR__)
  @android_main_activity Path.expand(
                           "../../android/app/src/main/java/com/example/casein_mob/MainActivity.kt",
                           __DIR__
                         )

  test "resolves the application identifier from the provisioning prefix and bundle settings" do
    entitlements = File.read!(@entitlements)
    project = File.read!(@xcode_project)
    profile = File.read!(@development_profile)

    assert build_setting_values(project, "DEVELOPMENT_TEAM") == ["2MP8QWK7R6"]
    assert build_setting_occurrences(project, "DEVELOPMENT_TEAM") == 6

    assert build_setting_values(project, "PRODUCT_BUNDLE_IDENTIFIER") == [
             "com.alexandrefamilyfarm.casein-mob",
             "com.alexandrefamilyfarm.casein-mob.soak-ui-tests",
             "com.alexandrefamilyfarm.casein-mob.feed-lifecycle-ui-tests"
           ]

    assert build_setting_occurrences(project, "PRODUCT_BUNDLE_IDENTIFIER") == 6

    assert build_setting_frequency(project, "PRODUCT_BUNDLE_IDENTIFIER") == %{
             "com.alexandrefamilyfarm.casein-mob" => 2,
             "com.alexandrefamilyfarm.casein-mob.soak-ui-tests" => 2,
             "com.alexandrefamilyfarm.casein-mob.feed-lifecycle-ui-tests" => 2
           }

    assert build_setting_values(project, "CODE_SIGN_ENTITLEMENTS") == [
             "CaseinMob.entitlements",
             "CaseinMob.Release.entitlements"
           ]

    assert build_setting_occurrences(project, "CODE_SIGN_ENTITLEMENTS") == 2

    assert build_setting_frequency(project, "CODE_SIGN_ENTITLEMENTS") == %{
             "CaseinMob.entitlements" => 1,
             "CaseinMob.Release.entitlements" => 1
           }

    debug_cfg = configuration_block!(project, "AA00000B /* Debug */")
    release_cfg = configuration_block!(project, "AA00000C /* Release */")

    assert debug_cfg =~ "CODE_SIGN_STYLE = Automatic;"
    assert debug_cfg =~ "CODE_SIGN_ENTITLEMENTS = CaseinMob.entitlements;"
    refute debug_cfg =~ "CaseinMob.Release.entitlements"
    refute debug_cfg =~ "Apple Distribution"
    refute debug_cfg =~ "PROVISIONING_PROFILE_SPECIFIER"

    assert release_cfg =~ "CODE_SIGN_STYLE = Manual;"
    assert release_cfg =~ ~s(CODE_SIGN_IDENTITY = "Apple Distribution";)
    assert release_cfg =~ "CODE_SIGN_ENTITLEMENTS = CaseinMob.Release.entitlements;"
    refute release_cfg =~ "CODE_SIGN_ENTITLEMENTS = CaseinMob.entitlements;"
    assert release_cfg =~
             ~s(PROVISIONING_PROFILE_SPECIFIER = "iOS Team Store Provisioning Profile: com.alexandrefamilyfarm.casein-mob";)

    [application_identifier_prefix] =
      plist_array_values!(profile, "ApplicationIdentifierPrefix")

    production_bundle_identifier = "com.alexandrefamilyfarm.casein-mob"

    expected_application_identifier =
      "#{application_identifier_prefix}." <>
        production_bundle_identifier

    # Mob signs the full application by passing this plist directly to codesign,
    # outside Xcode. Keep the resolved value here: Xcode build variables would
    # otherwise be signed literally by that path.
    assert entitlement_value!(entitlements, "application-identifier") ==
             expected_application_identifier

    refute entitlements =~ "$(AppIdentifierPrefix)"
    refute entitlements =~ "$(PRODUCT_BUNDLE_IDENTIFIER)"

    assert entitlement_value!(profile, "application-identifier") ==
             expected_application_identifier

    assert plist_array_values!(profile, "TeamIdentifier") == ["2MP8QWK7R6"]

    assert entitlement_value!(entitlements, "com.apple.developer.team-identifier") ==
             entitlement_value!(profile, "com.apple.developer.team-identifier")

    assert entitlement_value!(entitlements, "aps-environment") ==
             entitlement_value!(profile, "aps-environment")

    assert plist_array_values!(entitlements, "keychain-access-groups") ==
             plist_array_values!(profile, "keychain-access-groups")

    assert boolean_entitlement!(entitlements, "get-task-allow")
    assert boolean_entitlement!(profile, "get-task-allow")
  end

  test "Release configuration uses a distinct distribution entitlement and profile contract" do
    release_entitlements = File.read!(@release_entitlements)
    project = File.read!(@xcode_project)
    profile = File.read!(@distribution_profile)

    release_cfg = configuration_block!(project, "AA00000C /* Release */")
    assert release_cfg =~ "CODE_SIGN_ENTITLEMENTS = CaseinMob.Release.entitlements;"
    assert release_cfg =~ "CODE_SIGN_STYLE = Manual;"
    assert release_cfg =~ ~s(CODE_SIGN_IDENTITY = "Apple Distribution";)

    [application_identifier_prefix] =
      plist_array_values!(profile, "ApplicationIdentifierPrefix")

    expected_application_identifier =
      "#{application_identifier_prefix}.com.alexandrefamilyfarm.casein-mob"

    assert entitlement_value!(release_entitlements, "application-identifier") ==
             expected_application_identifier

    assert entitlement_value!(release_entitlements, "com.apple.developer.team-identifier") ==
             entitlement_value!(profile, "com.apple.developer.team-identifier")

    assert entitlement_value!(release_entitlements, "aps-environment") == "production"
    assert entitlement_value!(profile, "aps-environment") == "production"

    assert entitlement_value!(release_entitlements, "aps-environment") ==
             entitlement_value!(profile, "aps-environment")

    assert plist_array_values!(release_entitlements, "keychain-access-groups") ==
             plist_array_values!(profile, "keychain-access-groups")

    refute release_entitlements =~ "<key>get-task-allow</key>"
    refute profile =~ "<key>get-task-allow</key>"
    assert boolean_entitlement!(release_entitlements, "beta-reports-active")
    assert boolean_entitlement!(profile, "beta-reports-active")

    # Development push entitlement must remain intact on the Debug plist.
    development = File.read!(@entitlements)
    assert entitlement_value!(development, "aps-environment") == "development"
    assert boolean_entitlement!(development, "get-task-allow")
  end

  test "uses the resizable iPad window model with a launch screen" do
    plist = File.read!(@info_plist)

    refute plist =~ "UIRequiresFullScreen"
    assert plist =~ "<key>UILaunchScreen</key>"
    assert plist =~ "<key>UISupportedInterfaceOrientations~ipad</key>"

    for orientation <- [
          "UIInterfaceOrientationPortrait",
          "UIInterfaceOrientationPortraitUpsideDown",
          "UIInterfaceOrientationLandscapeLeft",
          "UIInterfaceOrientationLandscapeRight"
        ] do
      assert plist =~ "<string>#{orientation}</string>"
    end
  end

  test "uses the canonical Casein display name without changing app routing identity" do
    plist = File.read!(@info_plist)

    assert plist =~ "<key>CFBundleDisplayName</key>\n    <string>Casein</string>"
    assert plist =~ "<string>com.alexandrefamilyfarm.casein-mob</string>"
    assert plist =~ "<string>com.alexandrefamilyfarm.casein-mob.review</string>"
    assert plist =~ "<string>casein</string>"
    assert plist =~ "Casein uses the camera"
    assert plist =~ "Casein connects to Casein hosts"
    assert plist =~ "Casein uses the microphone"
    refute plist =~ "CaseinMob uses"
    refute plist =~ "CaseinMob connects"
  end

  test "routes pair and review deep links through the native notification bridge" do
    app_delegate = File.read!(@app_delegate)

    assert app_delegate =~ "MobNotificationJSONFromReviewURL"
    assert app_delegate =~ "MobNotificationJSONFromPairURL"
    assert app_delegate =~ ~s(@"action": @"mobile.pair")
    assert app_delegate =~ ~s(@"pairing_code": code)
    assert app_delegate =~ "MOB_PAIRING_CODE_MAX_BYTES"
    assert app_delegate =~ "components.fragment != nil"
    assert app_delegate =~ "components.user != nil"
    assert app_delegate =~ "BOOL hasQuery = components.percentEncodedQuery != nil;"
    refute app_delegate =~ ~s(@"pairing_code": code,\n        @"deep_link": url.absoluteString)
    assert app_delegate =~ "MobStoreDeepLinkURL(context.URL)"
    assert app_delegate =~ "return MobStoreDeepLinkURL(url);"
  end

  test "links against Mob runtimes before direct notification callbacks were added" do
    app_delegate = File.read!(@app_delegate)

    assert app_delegate =~
             "__attribute__((weak)) void mob_deliver_notification_json(const char* json)"

    assert app_delegate =~ "NSClassFromString(@\"MobNotificationDelegate\")"
    assert app_delegate =~ "enif_make_atom(env, \"mob_screen\")"
    assert app_delegate =~ "enif_make_atom(env, \"mob_launch_notification\")"
    assert app_delegate =~ "MOB_NOTIFICATION_JSON_MAX_BYTES"
    assert app_delegate =~ "mob_set_launch_notification_json(json);"

    assert app_delegate =~
             "__attribute__((weak)) void mob_send_push_token_error(const char* reason)"
  end

  test "review deep links preserve only origin-qualified resume locator fields" do
    app_delegate = File.read!(@app_delegate)
    android_main_activity = File.read!(@android_main_activity)

    for field <-
          ~w(origin_id workspace_id session_id task_type task_id tmux_session window pane tab artifact) do
      assert app_delegate =~ ~s(@"#{field}")
      assert android_main_activity =~ ~s("#{field}")
    end

    refute app_delegate =~ ~s(@"token", @"origin_id")
    refute android_main_activity =~ ~s("token", "origin_id")
  end

  defp build_setting_values(project, setting) do
    project
    |> build_setting_matches(setting)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp build_setting_occurrences(project, setting) do
    project
    |> build_setting_matches(setting)
    |> length()
  end

  defp build_setting_frequency(project, setting) do
    project
    |> build_setting_matches(setting)
    |> List.flatten()
    |> Enum.frequencies()
  end

  defp build_setting_matches(project, setting) do
    ~r/\b#{Regex.escape(setting)} = "?([^";]+)"?;/
    |> Regex.scan(project, capture: :all_but_first)
  end

  defp entitlement_value!(entitlements, key) do
    regex =
      ~r/<key>#{Regex.escape(key)}<\/key>\s*<string>([^<]+)<\/string>/

    case Regex.run(regex, entitlements, capture: :all_but_first) do
      [value] -> value
      _ -> flunk("missing string entitlement #{key}")
    end
  end

  defp plist_array_values!(plist, key) do
    array_regex =
      ~r/<key>#{Regex.escape(key)}<\/key>\s*<array>(.*?)<\/array>/s

    with [array] <- Regex.run(array_regex, plist, capture: :all_but_first) do
      ~r/<string>([^<]+)<\/string>/
      |> Regex.scan(array, capture: :all_but_first)
      |> List.flatten()
    else
      _ -> flunk("missing array #{key}")
    end
  end

  defp boolean_entitlement!(plist, key) do
    regex = ~r/<key>#{Regex.escape(key)}<\/key>\s*<(true|false)\/>/

    case Regex.run(regex, plist, capture: :all_but_first) do
      ["true"] -> true
      ["false"] -> false
      _ -> flunk("missing boolean entitlement #{key}")
    end
  end

  defp configuration_block!(project, marker) do
    pattern =
      ~r/#{Regex.escape(marker)} = \{(.*?)\t\t\};/s

    case Regex.run(pattern, project) do
      [_, block] -> block
      _ -> flunk("missing configuration #{marker}")
    end
  end
end
