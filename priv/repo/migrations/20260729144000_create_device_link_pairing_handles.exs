defmodule Casein.Repo.Migrations.CreateDeviceLinkPairingHandles do
  use Ecto.Migration

  def change do
    create table(:device_link_pairing_handles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :handle_hash, :text, null: false
      add :origin_id, :text, null: false
      add :origin_base_url, :text, null: false
      add :subject_id, :text, null: false
      add :subject_email, :text
      add :subject_role, :text, null: false
      add :resource_kind, :text, null: false
      add :resource_id, :text, null: false
      add :resource_label, :text
      add :capabilities, {:array, :string}, null: false, default: []
      add :audience, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:device_link_pairing_handles, [:handle_hash])

    create unique_index(
             :device_link_pairing_handles,
             [:origin_id, :subject_id, :resource_kind, :resource_id],
             where: "consumed_at IS NULL AND revoked_at IS NULL",
             name: :device_link_pairing_handles_one_active_scope_index
           )

    create index(:device_link_pairing_handles, [:resource_kind, :resource_id])
    create index(:device_link_pairing_handles, [:subject_id])
    create index(:device_link_pairing_handles, [:expires_at])
  end
end
