# #936: every mix.lock package must appear in audits or grandfathered.
# A new dep that is in neither fails test/hex_vet_ledger_test.exs.
# grandfathered is the :new_only incumbent set as of 2026-08-13; do not
# add names to it — vet them.
%{
  imports: %{},
  audits: [
    %{
      version: "1.1.1",
      package: "file_system",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-07-21 deps re-audit: promoted transitive (phoenix_live_reload/credo) to direct dep for Casein.Files.Watcher; same locked version, no new code fetched; pure-Elixir inotify wrapper.",
      reviewed_at: ~D[2026-07-21]
    },
    %{
      version: "0.22.4",
      package: "postgrex",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-08-07 security bump for EEF-CVE-2026-66838 (SQL injection via the :comment option in Postgrex.stream/4). Diff vs 0.22.3 is three files: a one-line comment_not_present!(options) guard in stream/4, the @version bump, and the CHANGELOG entry — nothing else. Phase 1 rules clean: no bidi/invisible unicode, no compile-time execution, no mix.exs compile hooks or custom compilers, no non-source files. Casein calls no Postgrex.stream/4 anywhere, so live exposure was nil; bumped to clear the advisory that was failing the gate on every open PR.",
      reviewed_at: ~D[2026-08-07]
    },
    %{
      version: "0.5.0",
      package: "ghostty",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-08-13 #936: single-author NIF (dannote/ghostty_ex, MIT). Terminal engine — libghostty-vt NIFs via zigler_precompiled. Residual risk is the precompiled-binary download; accepted because (1) mix.lock outer checksum 1788dc9ba8eda219bd79706525d55a0761f79a23847e0b72b150288714f12a6c, (2) mix.exs patch-only ~> 0.5.0 pin (a pre-1.0 minor is breaking by convention; three coordinated copies in-repo), (3) scripts/check-vendor-pin-guard.sh pins the vendored JS/artifact SHA. Hex 0.5.0 2026-07-29. Do not bump without a coordinated review of this NIF, assets/vendor/ghostty, and casein_ghostty_windows.",
      reviewed_at: ~D[2026-08-13]
    },
    %{
      version: "0.1.5",
      package: "zigler_precompiled",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-08-13 #936: single-author (dannote/zigler_precompiled, MIT). This is the package that downloads precompiled Zig NIFs — exactly the ledger's job. Offset by its own checksum-*.exs mechanism plus mix.lock outer checksum 4ee01cfdcd703215cf331f1ecc4324874ee2e3bfe15e7b2f3d65231c551a0571. Pulled in only via ghostty. Hex 0.1.5 2026-07-20. A version bump is a new precompiled-binary trust decision, not a routine patch.",
      reviewed_at: ~D[2026-08-13]
    },
    %{
      version: "0.3.3",
      package: "boxart",
      criteria: :safe_to_run,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-08-13 #936: same author as the ghostty NIF chain (dannote/boxart, MIT) but not itself a NIF — Unicode box-drawing over libgraph. mix.exs only: [:dev, :test], runtime: false, so :safe_to_run not :safe_to_deploy. mix.lock outer checksum 7b5668d280aed93e729a4e109c9f648705798d7fc6a7cdc40509acadf0925357. Hex 0.3.3 2026-04-27.",
      reviewed_at: ~D[2026-08-13]
    },
    %{
      version: "0.17.8",
      package: "oxc",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-08-13 #936: Rust NIF (elixir-volt/oxc_ex, MIT) pulled in by ghostty. Different maintainer than the dannote chain; still a precompiled rustler_precompiled NIF. mix.lock outer checksum 590fddfadbf843d6ab94e0f04a0e769a38358a23140728095da476c8c81f4df1. Hex 0.17.8 2026-07-21. rustler_precompiled is grandfathered separately; an oxc bump is a new native-binary trust decision.",
      reviewed_at: ~D[2026-08-13]
    }
  ],
  grandfathered: [
    "bandit",
    "boundary",
    "bunt",
    "castore",
    "cc_precompiler",
    "circular_buffer",
    "credo",
    "db_connection",
    "decimal",
    "dialyxir",
    "dns_cluster",
    "ecto",
    "ecto_sql",
    "ecto_sqlite3",
    "elixir_make",
    "eqrcode",
    "erlex",
    "erlexec",
    "esbuild",
    "ex_ast",
    "ex_machina",
    "ex_slop",
    "expo",
    "exqlite",
    "finch",
    "fine",
    "fuse",
    "gettext",
    "glob_ex",
    "hammer",
    "heroicons",
    "hpax",
    "idna",
    "igniter",
    "jason",
    "jido_action",
    "jido_signal",
    "lazy_html",
    "libgraph",
    "mdex",
    "mdex_native",
    "mime",
    "mint",
    "mint_web_socket",
    "mix_audit",
    "multigraph",
    "nimble_options",
    "nimble_parsec",
    "nimble_pool",
    "oban",
    "owl",
    "phoenix",
    "phoenix_ecto",
    "phoenix_html",
    "phoenix_live_dashboard",
    "phoenix_live_reload",
    "phoenix_live_view",
    "phoenix_pubsub",
    "phoenix_template",
    "plug",
    "plug_crypto",
    "req",
    "rewrite",
    "rustler_precompiled",
    "sobelow",
    "sourceror",
    "spitfire",
    "splode",
    "swoosh",
    "tailwind",
    "telemetry",
    "telemetry_metrics",
    "telemetry_poller",
    "text_diff",
    "thousand_island",
    "tidewave",
    "websock",
    "websock_adapter",
    "yamerl",
    "yaml_elixir",
    "zoi"
  ],
  policy: %{criteria_required: :safe_to_deploy, block_on_unvetted: :new_only}
}
