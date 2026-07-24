defmodule Casein.Repo.Migrations.CreateCommandRunRecords do
  use Ecto.Migration

  def change do
    create table(:command_run_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :text, null: false
      add :actor_id, :text
      add :command_id, :text, null: false
      add :argv, :map, null: false, default: %{}
      add :status, :text, null: false
      add :exit_code, :text
      add :output, :text
      add :output_truncated, :boolean, null: false, default: false
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :duration_ms, :integer
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:command_run_records, [:workspace_id, "started_at desc"])
    create index(:command_run_records, [:command_id, "started_at desc"])
    create index(:command_run_records, [:status, "started_at desc"])
  end
end
