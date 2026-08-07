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
    }
  ],
  policy: %{criteria_required: :safe_to_deploy, block_on_unvetted: :new_only}
}
