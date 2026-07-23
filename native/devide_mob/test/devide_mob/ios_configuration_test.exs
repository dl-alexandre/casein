defmodule DevideMob.IOSConfigurationTest do
  use ExUnit.Case, async: true

  @info_plist Path.expand("../../ios/Info.plist", __DIR__)

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
end
