defmodule DevideMob.IOSConfigurationTest do
  use ExUnit.Case, async: true

  @info_plist Path.expand("../../ios/Info.plist", __DIR__)
  @app_delegate Path.expand("../../ios/AppDelegate.m", __DIR__)

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
end
