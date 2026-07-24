%{
  imports: %{},
  audits: [
    %{
      package: "file_system",
      version: "1.1.1",
      criteria: :safe_to_deploy,
      reviewer: "dalexandre@milcgroup.com",
      notes:
        "2026-07-21 deps re-audit: promoted transitive (phoenix_live_reload/credo) to direct dep for Casein.Files.Watcher; same locked version, no new code fetched; pure-Elixir inotify wrapper.",
      reviewed_at: ~D[2026-07-21]
    }
  ],
  policy: %{criteria_required: :safe_to_deploy, block_on_unvetted: :new_only}
}
