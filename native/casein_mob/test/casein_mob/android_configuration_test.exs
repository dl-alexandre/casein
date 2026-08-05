defmodule CaseinMob.AndroidConfigurationTest do
  use ExUnit.Case, async: true

  @manifest Path.expand("../../android/app/src/main/AndroidManifest.xml", __DIR__)
  @gradle Path.expand("../../android/app/build.gradle", __DIR__)
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

  test "preserves only staged ERTS executables byte-for-byte across every packaged ABI" do
    gradle = File.read!(@gradle)

    assert gradle =~ "keepDebugSymbols += ["

    helpers =
      Regex.scan(~r/'\*\*\/(lib[^']+\.so)'/, gradle, capture: :all_but_first)
      |> List.flatten()

    assert helpers == ["libepmd.so", "liberl_child_setup.so", "libinet_gethost.so"]

    # ABI wildcards apply the same exact allowlist to arm64-v8a,
    # armeabi-v7a, and x86_64. Ordinary JNI libraries retain AGP's existing
    # stripping behavior rather than silently widening the exception.
    [abi_filter_line] =
      Regex.run(~r/ndk \{ abiFilters ([^}]+) \}/, gradle, capture: :all_but_first)

    abis = Regex.scan(~r/'([^']+)'/, abi_filter_line, capture: :all_but_first) |> List.flatten()

    assert abis == ["arm64-v8a", "armeabi-v7a", "x86_64"]

    packaged_helper_paths =
      for abi <- abis, helper <- helpers do
        "lib/#{abi}/#{helper}"
      end

    assert length(packaged_helper_paths) == 9
    assert Enum.uniq(packaged_helper_paths) == packaged_helper_paths

    refute gradle =~ "**/libcasein_mob.so"
    refute gradle =~ "**/libsqlite3_nif.so"
    refute gradle =~ "**/*.so"
  end
end
