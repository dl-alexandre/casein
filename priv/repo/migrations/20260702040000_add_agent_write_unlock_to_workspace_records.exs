defmodule Casein.Repo.Migrations.AddAgentWriteUnlockToWorkspaceRecords do
  use Ecto.Migration

  def change do
    alter table(:workspace_records) do
      add :agent_write_unlocked_until, :utc_datetime_usec
      add :agent_write_unlocked_by, :text
      add :agent_write_unlock_granted_at, :utc_datetime_usec
    end

    create index(:workspace_records, [:agent_write_unlocked_until])
  end
end
