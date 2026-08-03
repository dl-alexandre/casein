# mob.exs — Mob build environment configuration.
# Set these paths for your machine. Not committed to version control.
# (Add mob.exs to .gitignore if you share this project.)
#
# OTP runtimes for Android and iOS are downloaded automatically by `mix mob.install`.

import Config

config :mob_dev,
  # Mob currently exposes one cross-platform bundle-id setting. Keep the iOS
  # signing identifier as the default and let Android deploys select the
  # generated Gradle applicationId explicitly:
  #
  #   MOB_BUNDLE_ID=com.example.casein_mob mix mob.deploy --native --device <serial>
  bundle_id: System.get_env("MOB_BUNDLE_ID") || "com.alexandrefamilyfarm.casein-mob",
  # Path to the mob library repo (native source files for iOS/Android builds).
  mob_dir: Path.join(File.cwd!(), "deps/mob"),

  # Path to your Elixir lib dir (e.g. ~/.local/share/mise/installs/elixir/1.18.4-otp-28/lib).
  elixir_lib:
    System.get_env("MOB_ELIXIR_LIB", :code.lib_dir(:elixir) |> to_string() |> Path.dirname()),
  # On-device terminal VT NIF. arm64-v8a ONLY — we have the
  # aarch64-linux-android libghostty-vt.a (built off-host on the devbox); :android
  # would also pull arm32, which we don't have. The :guard gates the platform-wide
  # driver_tab row to arm64; :extra_static_libs static-links libghostty-vt.a into
  # the app so the NIF's `extern ghostty_terminal_*` symbols resolve at app link
  # (the NIF itself host-links nothing). See docs/subsystems/mob_ondevice_terminal_gate.md.
  static_nifs: [
    %{
      module: :ghostty_vt,
      archs: [:android_arm64],
      guard: "MOB_STATIC_GHOSTTY_VT_NIF",
      extra_static_libs: %{
        android_arm64: "native/ghostty_vt/lib-android-arm64/libghostty-vt.a"
      }
    }
  ]

# Activated capability plugins (the packages added in mix.exs). Each contributes
# its native code, permissions, and any demo screens at build time. Drop a name
# here to deactivate a plugin without removing the dep; remove both to drop it
# entirely (the native build shrinks and a clean rebuild prunes its artifacts).
config :mob, :plugins, [:mob_camera, :mob_scanner, :mob_location, :mob_biometric, :mob_notify]

# Trust gate for the first-party plugins. Each entry pins the exact reviewed
# author or controlled-fork key; the checksum-pinned Hex plugins share the mob
# release key while the reviewed mob_notify fork uses its dedicated key. The
# build refuses an ACTIVATED plugin whose signature doesn't verify against its
# trusted fingerprint (tamper protection). Entries for inactive plugins are
# unused. For your own/third-party plugins, run
# `mix mob.plugin.trust <name>`, or `config :mob, :acknowledge_unsafe_plugins,
# [...]` for an unsigned prototype.
config :mob, :trusted_plugins, %{
  mob_camera: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_scanner: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_location: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_biometric: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_notify: "ed25519:4/l+KAfhgFdCvwR77Bl6ECgOB2EuzVo3u3DntcHtHTE=",
  mob_bluetooth: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_screencast: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_photos: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg=",
  mob_ash: "ed25519:nc56w+1Kx0gIt/4EkHxnMZCKHMzp4+S5kS/HoSzEZkg="
}

# Style packages (theming). :default_style selects the theme applied at boot.
config :mob, :styles, [:mob_themes]
config :mob, :default_style, :mob_themes
