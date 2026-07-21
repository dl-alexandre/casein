%{
  imports: %{},
  audits: [
    %{
      package: "cowlib",
      version: "2.18.0",
      criteria: :safe_to_run,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-07-21 deps re-audit: EEF-CVE-2026-43966 (MEDIUM) / EEF-CVE-2026-43969 (LOW) known and unpatched upstream (2.18.0 is latest); scoped only: [:dev, :test] in mix.exs so it never ships in prod releases (verified 0/64 prod deps). safe_to_run only — bump and re-vet when >2.18.0 ships.",
      reviewed_at: ~D[2026-07-21]
    },
    %{
      package: "file_system",
      version: "1.1.1",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-07-21 deps re-audit: promoted transitive (phoenix_live_reload/credo) to direct dep for DevIDE.Files.Watcher; same locked version, no new code fetched; pure-Elixir inotify wrapper.",
      reviewed_at: ~D[2026-07-21]
    }
  ],
  policy: %{criteria_required: :safe_to_deploy, block_on_unvetted: :new_only}
}
