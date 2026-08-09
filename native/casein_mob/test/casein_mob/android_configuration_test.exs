defmodule CaseinMob.AndroidConfigurationTest do
  use ExUnit.Case, async: true

  @manifest Path.expand("../../android/app/src/main/AndroidManifest.xml", __DIR__)
  @gradle Path.expand("../../android/app/build.gradle", __DIR__)
  @styles Path.expand("../../android/app/src/main/res/values/styles.xml", __DIR__)
  @colors Path.expand("../../android/app/src/main/res/values/colors.xml", __DIR__)
  @strings Path.expand("../../android/app/src/main/res/values/strings.xml", __DIR__)
  @main_activity Path.expand(
                    "../../android/app/src/main/java/com/example/casein_mob/MainActivity.kt",
                    __DIR__
                  )
  @cold_start_progress Path.expand(
                         "../../android/app/src/main/java/com/example/casein_mob/ColdStartProgress.kt",
                         __DIR__
                       )
  @cold_start_surface Path.expand(
                        "../../android/app/src/main/java/com/example/casein_mob/ColdStartSurface.kt",
                        __DIR__
                      )
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
    strings = File.read!(@strings)

    assert manifest =~ ~s(android:label="@string/app_name")
    refute manifest =~ ~s(android:label="CaseinMob")
    assert strings =~ ~s(name="app_name">Casein</string>)
    assert manifest =~ ~s(package="com.example.casein_mob")
    assert manifest =~ ~s(android:scheme="casein")
  end

  test "shows a static branded cold-start surface before the BEAM root is ready" do
    styles = File.read!(@styles)
    colors = File.read!(@colors)
    strings = File.read!(@strings)
    main = File.read!(@main_activity)
    progress = File.read!(@cold_start_progress)
    surface = File.read!(@cold_start_surface)

    # Immediate window chrome — not pure black (#410).
    assert styles =~ "@color/casein_cold_start_background"
    refute styles =~ "@android:color/black"
    assert colors =~ "casein_cold_start_background"
    assert colors =~ "#13171C"

    # Distinct starting / ready / failed phases (#731 discipline).
    assert progress =~ "enum class ColdStartPhase"
    assert progress =~ "Starting"
    assert progress =~ "Ready"
    assert progress =~ "Failed"
    assert progress =~ "NARRATION_REVEAL_MS"
    assert progress =~ "FAIL_CLOSED_MS"

    # Delayed narration only — no spin/pulse (motion scale #776/#778).
    assert progress =~ "200L"
    refute surface =~ "CircularProgress"
    refute surface =~ "InfiniteTransition"
    refute surface =~ "rememberInfiniteTransition"
    refute surface =~ "animateFloat"
    refute main =~ "CircularProgressIndicator"

    # Bounded static copy — no credentials, boot logs, or origin polling UI.
    assert strings =~ "cold_start_starting"
    assert strings =~ "cold_start_failed_title"
    refute strings =~ "MOB_"
    refute strings =~ "beam"
    refute strings =~ "otp"
    refute strings =~ "token"
    refute strings =~ "http"

    assert main =~ "ColdStartSurface"
    assert main =~ "ColdStartProgress"
    assert main =~ "coldStartSettledReady"
    # First root paint must not animate over the cold-start chrome.
    assert main =~ "First root paint"
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
