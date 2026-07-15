defmodule DevIDE.Repo.Migrations.CreatePushDevicesAndNotificationPreferences do
  use Ecto.Migration

  def change do
    alter table(:notifications) do
      add :occurrence_count, :integer, null: false, default: 1
      add :last_seen_at, :utc_datetime_usec
    end

    create table(:push_devices, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :text, null: false
      add :token, :text, null: false
      add :platform, :text, null: false
      add :scope, :text, null: false
      add :scope_id, :text, null: false
      add :user_id, :text
      add :workspace_id, :text
      add :device_link_id, :text
      add :push_subscription, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec, null: false
      add :disabled_at, :utc_datetime_usec
      add :failure_count, :integer, null: false, default: 0
      add :provider_status, :text, null: false, default: "active"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:push_devices, [:token_hash, :scope, :scope_id])
    create index(:push_devices, [:scope, :scope_id])
    create index(:push_devices, [:workspace_id])
    create index(:push_devices, [:user_id])
    create index(:push_devices, [:disabled_at])
    create index(:push_devices, [:last_seen_at])

    create table(:notification_preferences, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :text, null: false
      add :workspace_id, :text, null: false, default: "__global__"
      add :settings, :map, null: false, default: %{}
      add :quiet_hours, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_preferences, [:user_id, :workspace_id])
    create index(:notification_preferences, [:user_id])
  end
end
