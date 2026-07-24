defmodule Casein.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :text, null: false
      add :workspace_id, :text
      add :session_id, :text
      add :type, :text, null: false
      add :severity, :text, null: false, default: "info"
      add :title, :text, null: false
      add :body, :text
      add :metadata, :map, null: false, default: %{}
      add :dedupe_key, :text
      add :ttl_seconds, :integer
      add :expires_at, :utc_datetime_usec
      add :deep_link, :text

      add :channels, Casein.Repo.Adapter.list_storage_type(repo(), :text),
        null: false,
        default: Casein.Repo.Adapter.list_default(repo())

      add :default_delivery, :map, null: false, default: %{}
      add :source_type, :text
      add :source_id, :text
      add :read_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec
      add :muted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:notifications, [:user_id, "inserted_at desc"])
    create index(:notifications, [:user_id, :read_at])
    create index(:notifications, [:workspace_id, "inserted_at desc"])
    create index(:notifications, [:type, "inserted_at desc"])
    create index(:notifications, [:dedupe_key, "inserted_at desc"])
    create index(:notifications, [:source_type, :source_id])
  end
end
