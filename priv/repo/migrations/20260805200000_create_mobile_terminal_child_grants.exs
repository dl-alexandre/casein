defmodule Casein.Repo.Migrations.CreateMobileTerminalChildGrants do
  use Ecto.Migration

  def change do
    create table(:mobile_terminal_child_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :text, null: false
      add :user_id, :text, null: false

      add :device_link_id,
          references(:device_link_tokens, type: :binary_id, on_delete: :delete_all), null: false

      add :origin_id, :text, null: false
      add :origin_generation, :text, null: false
      add :workspace_id, :text, null: false

      add :lease_id,
          references(:mobile_terminal_sessions, type: :binary_id, on_delete: :delete_all),
          null: false

      add :lifecycle_generation, :binary_id, null: false
      add :sid, :text, null: false
      add :tmux_session, :text, null: false
      add :pane_id, :text, null: false
      add :pane_role, :text, null: false
      add :topology_generation, :text, null: false
      add :mode, :text, null: false, default: "read"
      add :connection_generation, :text
      add :begun_at, :utc_datetime_usec
      add :revoked_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mobile_terminal_child_grants, [:token_hash])
    create index(:mobile_terminal_child_grants, [:lease_id, :revoked_at])
    create index(:mobile_terminal_child_grants, [:device_link_id, :revoked_at])
    create index(:mobile_terminal_child_grants, [:expires_at])
  end
end
