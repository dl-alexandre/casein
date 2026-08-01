defmodule Casein.Repo.Migrations.CreateMcpTickets do
  use Ecto.Migration

  def change do
    create table(:mcp_tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :ticket_hash, :text, null: false
      add :capability_id, :binary_id, null: false
      add :workspace_id, :text, null: false
      add :surface, :text, null: false
      add :scopes, {:array, :string}, null: false, default: []
      add :runtime, :text, null: false
      add :tmux_session_id, :text
      add :pane_id, :text
      add :leader_id, :text
      add :bundle_digest, :text
      add :workspace_mode, :text
      add :checkout_digest, :text
      add :expires_at, :utc_datetime_usec, null: false
      add :consumed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mcp_tickets, [:ticket_hash])
    create index(:mcp_tickets, [:workspace_id, :surface])
    create index(:mcp_tickets, [:capability_id])
    create index(:mcp_tickets, [:expires_at])
  end
end
