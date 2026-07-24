defmodule Casein.Repo.Migrations.DropDelegatedExecutionTables do
  use Ecto.Migration

  # Tables for the removed delegated-execution stack (fleet + runner-assignment
  # protocol). No application code references them after the stack removal, so the
  # data is dead. Drop runner_progress_reports before runner_assignments because of
  # the FK (runner_progress_reports.assignment_id -> runner_assignments).
  #
  # Irreversible by design: the data is discarded and the schemas no longer exist,
  # so down/0 raises instead of silently recreating empty tables. To recover the
  # structure, revert to a commit before the stack removal.
  def up do
    drop_if_exists table(:runner_progress_reports)
    drop_if_exists table(:runner_assignments)
    drop_if_exists table(:assignment_events)
    drop_if_exists table(:fleet_artifact_chunks)
  end

  def down do
    raise "irreversible migration: delegated-execution tables were dropped with the stack removal"
  end
end
