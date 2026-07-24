defmodule Casein.Repo.Migrations.CreateSavedTemplates do
  use Ecto.Migration

  def up do
    if Casein.Repo.Adapter.sqlite?(repo()) do
      create_if_not_exists table(:saved_templates, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :workspace_id, :text, null: false
        add :name, :text, null: false
        add :description, :text
        add :body, :map, null: false, default: %{}
        add :source_session, :text
        add :schema_version, :integer, null: false, default: 2
        timestamps(type: :utc_datetime_usec)
      end

      create_if_not_exists index(:saved_templates, [:workspace_id])
      create_if_not_exists index(:saved_templates, [:workspace_id, "inserted_at desc"])
      create_if_not_exists index(:saved_templates, [:workspace_id, :name])
    else
      execute("""
      CREATE TABLE IF NOT EXISTS saved_templates (
        id uuid PRIMARY KEY,
        workspace_id text NOT NULL,
        name text NOT NULL,
        description text,
        body jsonb NOT NULL DEFAULT '{}'::jsonb,
        source_session text,
        schema_version integer NOT NULL DEFAULT 2,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL
      )
      """)

      execute(
        "ALTER TABLE saved_templates ADD COLUMN IF NOT EXISTS schema_version integer NOT NULL DEFAULT 2"
      )

      execute(
        "CREATE INDEX IF NOT EXISTS saved_templates_workspace_id_index ON saved_templates (workspace_id)"
      )

      execute("""
      CREATE INDEX IF NOT EXISTS saved_templates_workspace_id_inserted_at_desc_index
      ON saved_templates (workspace_id, inserted_at DESC)
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS saved_templates_workspace_id_name_index
      ON saved_templates (workspace_id, name)
      """)
    end
  end

  def down do
    drop_if_exists table(:saved_templates)
  end
end
