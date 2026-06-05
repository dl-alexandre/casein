defmodule DevIde.Repo.Migrations.ChangePreviewWorkspaceIdToString do
  use Ecto.Migration

  def up do
    execute """
    ALTER TABLE previews
    ALTER COLUMN workspace_id TYPE varchar(255)
    USING workspace_id::text
    """
  end

  def down do
    execute """
    ALTER TABLE previews
    ALTER COLUMN workspace_id TYPE uuid
    USING CASE
      WHEN workspace_id ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      THEN workspace_id::uuid
      ELSE NULL
    END
    """
  end
end
