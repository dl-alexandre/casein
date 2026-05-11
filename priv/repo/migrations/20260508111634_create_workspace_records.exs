defmodule DevIde.Repo.Migrations.CreateWorkspaceRecords do
  use Ecto.Migration

  def change do
    create table(:workspace_records, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :external_id, :text, null: false
      add :name, :text, null: false
      add :host_path, :text
      add :status, :text
      add :mode, :text
      add :db_isolation, :text
      add :db_isolation_source, :text
      add :db_isolation_summary, :text
      add :db_isolation_detected_at, :utc_datetime_usec
      add :manager_payload, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:workspace_records, [:external_id])
    create index(:workspace_records, [:name])
    create index(:workspace_records, [:status])
    create index(:workspace_records, [:mode])
    create index(:workspace_records, [:db_isolation])
  end
end
