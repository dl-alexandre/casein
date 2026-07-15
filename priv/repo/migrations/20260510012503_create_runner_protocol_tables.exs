defmodule DevIDE.Repo.Migrations.CreateRunnerProtocolTables do
  use Ecto.Migration

  def change do
    create table(:runner_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :text, null: false
      add :safe_action_id, :text, null: false
      add :safe_action_version, :integer, null: false
      add :status, :text, null: false
      add :requested_by, :text
      add :claimed_by, :text
      add :claim_token, :text
      add :queued_at, :utc_datetime_usec, null: false
      add :claimed_at, :utc_datetime_usec
      add :lease_expires_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec
      add :failure_reason, :text
      add :evidence, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:runner_assignments, [:status, "queued_at asc"])
    create index(:runner_assignments, [:workspace_id, "queued_at desc"])
    create index(:runner_assignments, [:safe_action_id, :status])
    create index(:runner_assignments, [:claimed_by, :status])

    create table(:runner_progress_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :assignment_id,
          references(:runner_assignments, type: :binary_id, on_delete: :delete_all),
          null: false

      add :runner_id, :text, null: false
      add :position, :integer, null: false
      add :event, :text, null: false
      add :stream, :text
      add :message, :text
      add :data, :text
      add :data_truncated, :boolean, null: false, default: false
      add :evidence, :map, null: false, default: %{}
      add :observed_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:runner_progress_reports, [:assignment_id, :position])
    create index(:runner_progress_reports, [:assignment_id, "position asc"])
  end
end
