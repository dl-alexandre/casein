defmodule DevIDE.Repo.Migrations.AddSourceToolToAuditEvents do
  use Ecto.Migration

  # Legacy MCP audit rows encode both surface and tool in the action string
  # ("agent.terminal_" <> tool, etc.). The backfill parses those prefixes into
  # the new dedicated columns; new rows get them stamped by
  # `DevIDE.Agents.MCPAudit`. Exposed as a function so the migration test can
  # run the exact statements against legacy-shaped fixture rows.
  @backfill_sql [
    """
    UPDATE audit_events
    SET source = 'terminal_mcp', tool = substr(action, 16)
    WHERE source IS NULL AND action LIKE 'agent.terminal!_%' ESCAPE '!'
    """,
    """
    UPDATE audit_events
    SET source = 'preview_mcp', tool = substr(action, 15)
    WHERE source IS NULL AND action LIKE 'agent.preview!_%' ESCAPE '!'
    """,
    """
    UPDATE audit_events
    SET source = 'artifact_mcp', tool = substr(action, 16)
    WHERE source IS NULL AND action LIKE 'agent.artifact!_%' ESCAPE '!'
    """
  ]

  def backfill_sql, do: @backfill_sql

  def up do
    alter table(:audit_events) do
      add :source, :text
      add :tool, :text
    end

    for sql <- @backfill_sql, do: execute(sql)

    create index(:audit_events, [:workspace_id, :source, "inserted_at desc"])
    create index(:audit_events, [:tool, "inserted_at desc"])
  end

  def down do
    drop index(:audit_events, [:workspace_id, :source, "inserted_at desc"])
    drop index(:audit_events, [:tool, "inserted_at desc"])

    alter table(:audit_events) do
      remove :source
      remove :tool
    end
  end
end
