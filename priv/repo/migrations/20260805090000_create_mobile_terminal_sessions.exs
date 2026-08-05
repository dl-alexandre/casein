defmodule Casein.Repo.Migrations.CreateMobileTerminalSessions do
  use Ecto.Migration

  def change do
    create table(:mobile_terminal_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :text, null: false
      add :device_link_id, :text, null: false
      add :origin_id, :text, null: false
      add :origin_generation, :text, null: false
      add :workspace_id, :text, null: false
      add :workspace_key, :text, null: false
      add :workspace_root, :text, null: false
      add :request_id, :binary_id, null: false
      add :request_fingerprint, :text, null: false
      add :sid, :text, null: false
      add :tmux_session, :text, null: false
      add :pane_id, :text
      add :pane_role, :text, null: false, default: "mobile_terminal"
      add :lifecycle_generation, :binary_id, null: false
      add :state, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
      add :failure_code, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mobile_terminal_sessions, [:device_link_id, :request_id],
             name: :mobile_terminal_sessions_device_request_index
           )

    create unique_index(:mobile_terminal_sessions, [:tmux_session])
    create index(:mobile_terminal_sessions, [:state, :expires_at])
    create index(:mobile_terminal_sessions, [:device_link_id, :workspace_id])

    create constraint(:mobile_terminal_sessions, :mobile_terminal_sessions_state_check,
             check: "state IN ('provisioning','active','deleting','deleted','expired','failed')"
           )

    create constraint(:mobile_terminal_sessions, :mobile_terminal_sessions_sid_check,
             check: "sid LIKE 'mob-%'"
           )
  end
end
