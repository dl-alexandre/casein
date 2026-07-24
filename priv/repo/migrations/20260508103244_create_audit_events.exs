defmodule Casein.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :text, null: false
      add :actor_id, :text
      add :action, :text, null: false
      add :target_type, :text
      add :target_ref, :text
      add :decision, :text
      add :reason, :text
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:audit_events, [:workspace_id, "inserted_at desc"])
    create index(:audit_events, [:action, "inserted_at desc"])
    create index(:audit_events, [:decision, "inserted_at desc"])
  end
end
