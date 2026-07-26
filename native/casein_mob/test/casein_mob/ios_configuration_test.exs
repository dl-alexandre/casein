defmodule CaseinMob.IOSConfigurationTest do
  use ExUnit.Case, async: true

  @info_plist Path.expand("../../ios/Info.plist", __DIR__)
  @app_delegate Path.expand("../../ios/AppDelegate.m", __DIR__)
  @android_main_activity Path.expand(
                           "../../android/app/src/main/java/com/example/casein_mob/MainActivity.kt",
                           __DIR__
                         )

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

  test "routes pair and review deep links through the native notification bridge" do
    app_delegate = File.read!(@app_delegate)

    assert app_delegate =~ "MobNotificationJSONFromReviewURL"
    assert app_delegate =~ "MobNotificationJSONFromPairURL"
    assert app_delegate =~ ~s(@"action": @"mobile.pair")
    assert app_delegate =~ ~s(@"pairing_code": code)
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
end
