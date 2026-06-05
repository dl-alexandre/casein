defmodule DevIde.Repo.Migrations.ChangePreviewSessionIdToString do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE previews
    ALTER COLUMN session_id TYPE varchar(255)
    USING session_id::text
    """
  end

  def down do
    execute """
    ALTER TABLE previews
    ALTER COLUMN session_id TYPE uuid
    USING CASE
      WHEN session_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN session_id::uuid
      ELSE NULL
    END
    """
  end
end
