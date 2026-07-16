defmodule DevIDE.Repo.Migrations.CreateAgentCapabilityTokens do
  use Ecto.Migration

  def change do
    create table(:agent_capability_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token_hash, :text, null: false
      add :workspace_id, :text, null: false
      add :runtime, :text, null: false
      add :tmux_session_id, :text, null: false
      add :pane_id, :text, null: false
      add :leader_id, :text, null: false
      add :bundle_digest, :text, null: false
      add :workspace_mode, :text, null: false
      add :allowed_tools, :map, null: false, default: %{}
      add :checkout_digest, :text
      add :revoked_at, :utc_datetime_usec
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_capability_tokens, [:token_hash])
    create index(:agent_capability_tokens, [:workspace_id])
    create index(:agent_capability_tokens, [:workspace_id, :tmux_session_id])
    create index(:agent_capability_tokens, [:workspace_id, :leader_id])

    create unique_index(:agent_capability_tokens, [:workspace_id, :leader_id],
             where: "revoked_at IS NULL",
             name: :agent_capability_tokens_active_leader_index
           )

    create index(:agent_capability_tokens, [:revoked_at])
    create index(:agent_capability_tokens, [:expires_at])
  end
end
