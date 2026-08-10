defmodule CaseinMob.MixProject do
  use Mix.Project

  def project do
    [
      app: :casein_mob,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: [:logger, :castore]]
  end

  defp deps do
    [
      # Fork branch for GenericJam/zigler#1: upstream Zigler 0.16 plus the
      # static-NIF build hooks Mob needs for native app linking.
      {:zigler,
       git: "https://github.com/dl-alexandre/zigler.git",
       ref: "50724d53cca71f1f45124b554d53c6f438973b04",
       override: true},
      {:mob,
       github: "dl-alexandre/mob", ref: "dd6ab6159aca279fa04bd8c4fd1bd5b48a27c621", override: true},
      # Exact merged MobDev head rejects macOS AppleDouble sidecars from
      # Android BEAM payload archives.
      {:mob_dev,
       git: "https://github.com/dl-alexandre/mob_dev.git",
       ref: "4a626ca8331f00bf0801ac751bc05c81735b738f",
       only: [:dev, :test],
       runtime: false,
       override: true},
      {:ecto_sqlite3, "~> 0.18"},
      # Phoenix Channel client for the session companion — connects to the
      # Casein host's `/socket` UserSocket over WSS and joins `session:<id>`.
      # Pure Elixir over Mint (`:mint_web_socket`), no NIFs, so it cross-compiles
      # cleanly for the device build. Jason is the channel JSON serializer.
      {:slipstream, "~> 1.1"},
      {:req, "~> 0.6"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.4"},
      # Terminal emulator (VT state machine + grid) — the Casein terminal
      # contract. NIF (Zig); builds for the host today. On-device arm64
      # cross-compile is the open gate (see CaseinMob.TerminalScreen moduledoc).
      {:ghostty, "~> 0.4"},
      # Showcase plugins — each ships a demo screen the home auto-lists, so a
      # fresh app demonstrates real device capabilities out of the box. Remove
      # any you don't need (and drop it from config :mob, :plugins in mob.exs);
      # the native build shrinks accordingly. Browse more at
      # https://hexdocs.pm/mob/packages.html.
      {:mob_camera, "~> 0.1"},
      # Vendored mob_scanner with DairyPhone #457 QR-preference fix.
      # Path dep is unsigned; acknowledged in mob.exs.
      {:mob_scanner, path: "vendor/mob_scanner", override: true},
      {:mob_location, "~> 0.1"},
      {:mob_biometric, "~> 0.1"},
      # 0.1.3 fork master: signed-v2 + Android push_token_error bridge/JNI
      # (cached blank, firebase blank, task failure). Template == tracked copy.
      {:mob_notify,
       github: "dl-alexandre/mob_notify",
       ref: "936137f31a47f47ae29b3400f504662502047252",
       override: true},
      # Brand theming is CaseinMob.Theme (in-tree), not Hex mob_themes. The stock
      # showcase pack boots Obsidian violet and is not our product look — see
      # CaseinMob.Theme moduledoc and docs/subsystems/mob_dev_workflow.md.
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end
end
