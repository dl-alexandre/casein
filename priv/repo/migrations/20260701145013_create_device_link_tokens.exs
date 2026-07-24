defmodule Casein.Repo.Migrations.CreateDeviceLinkTokens do
  use Ecto.Migration

  def change do
    create table(:device_link_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :origin_id, :text, null: false
      add :origin_name, :text, null: false
      add :subject_id, :text, null: false
      add :subject_email, :text
      add :subject_role, :text, null: false
      add :token_hash, :text, null: false
      add :resource_kind, :text, null: false
      add :resource_id, :text, null: false
      add :resource_label, :text
      add :capabilities, {:array, :string}, null: false, default: []
      add :device_name, :text
      add :platform, :text
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_link_tokens, [:token_hash])
    create index(:device_link_tokens, [:subject_id])
    create index(:device_link_tokens, [:resource_kind, :resource_id])
    create index(:device_link_tokens, [:revoked_at])
  end
end
