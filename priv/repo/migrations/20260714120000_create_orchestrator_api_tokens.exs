defmodule DevIde.Repo.Migrations.CreateOrchestratorApiTokens do
  use Ecto.Migration

  def change do
    create table(:orchestrator_api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :text, null: false
      add :subject_id, :text, null: false
      add :subject_email, :text
      add :subject_role, :text, null: false
      add :label, :text
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:orchestrator_api_tokens, [:token_hash])
    create index(:orchestrator_api_tokens, [:subject_id])
    create index(:orchestrator_api_tokens, [:revoked_at])
    create index(:orchestrator_api_tokens, [:expires_at])
  end
end
