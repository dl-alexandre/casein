defmodule DevIde.Repo.Migrations.RecreateObanTables do
  use Ecto.Migration

  # Prod already executed master's drop_oban_tables (20260620030000) AND still
  # records add_oban_jobs_table (20260612160000) as applied. This branch
  # re-introduces Oban (loops/maintenance/default queues), but a forward
  # `up all` recreates nothing for Oban — the recorded versions are unchanged
  # and the file revert can't undo what the DB already ran. The release then
  # boots, Oban queries oban_peers, and crashes (relation does not exist).
  #
  # A fresh version reruns Oban.Migrations.up/0 to recreate the full Oban schema
  # (oban_jobs, oban_peers, …). It is idempotent: up/0 only creates what the
  # current schema version lacks, so this is safe on envs that still have the
  # tables (CI, future fresh DBs) as well as on prod where they were dropped.
  def up, do: Oban.Migrations.up()

  def down, do: Oban.Migrations.down()
end
