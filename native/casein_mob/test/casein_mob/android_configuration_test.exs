defmodule CaseinMob.AndroidConfigurationTest do
  use ExUnit.Case, async: true

  @manifest Path.expand("../../android/app/src/main/AndroidManifest.xml", __DIR__)
  @mob_notify_bridge Path.expand(
                       "../../android/app/src/main/java/io/mob/notify/MobNotifyBridge.kt",
                       __DIR__
                     )
  @dependency_mob_notify_bridge Path.join(
                                  Map.fetch!(Mix.Project.deps_paths(), :mob_notify),
                                  "priv/native/android/MobNotifyBridge.kt"
                                )

  test "uses the canonical public app label without changing stable routing identifiers" do
    manifest = File.read!(@manifest)

    assert manifest =~ ~s(android:label="Casein")
    refute manifest =~ ~s(android:label="CaseinMob")
    assert manifest =~ ~s(package="com.example.casein_mob")
    assert manifest =~ ~s(android:scheme="casein")
  end

  test "tracks the reviewed host-agnostic mob_notify Android bridge exactly" do
    bridge = File.read!(@mob_notify_bridge)

    assert bridge == File.read!(@dependency_mob_notify_bridge)

    assert bridge =~
             "external fun nativeDeliverNotifyPushTokenError(pid: Long, reason: String)"

    assert bridge =~ "nativeDeliverNotifyPushTokenError(pid, reason)"
    assert bridge =~ ~S|deliverPushTokenError(pid, "cached_token_blank")|
    assert bridge =~ ~S|deliverPushTokenError(pid, "firebase_token_blank")|
    assert bridge =~ "firebase_token_fetch_failed"
    refute bridge =~ "com.example.casein_mob"
  end
end
