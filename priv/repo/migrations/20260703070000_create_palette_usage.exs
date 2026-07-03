defmodule DevIde.Repo.Migrations.CreatePaletteUsage do
  use Ecto.Migration

  def up do
    if DevIDE.Repo.Adapter.sqlite?(repo()) do
      create_if_not_exists table(:palette_usage, primary_key: false) do
        add :id, :binary_id, primary_key: true
        add :workspace_id, :text, null: false
        add :item_id, :text, null: false
        add :uses, :integer, null: false, default: 1
        add :last_used_at, :utc_datetime_usec, null: false
        timestamps(type: :utc_datetime_usec)
      end

      create_if_not_exists unique_index(:palette_usage, [:workspace_id, :item_id])
      create_if_not_exists index(:palette_usage, [:workspace_id, "last_used_at desc"])
    else
      execute("""
      CREATE TABLE IF NOT EXISTS palette_usage (
        id uuid PRIMARY KEY,
        workspace_id text NOT NULL,
        item_id text NOT NULL,
        uses integer NOT NULL DEFAULT 1,
        last_used_at timestamp(6) without time zone NOT NULL,
        inserted_at timestamp(6) without time zone NOT NULL,
        updated_at timestamp(6) without time zone NOT NULL
      )
      """)

      execute("""
      CREATE UNIQUE INDEX IF NOT EXISTS palette_usage_workspace_id_item_id_index
      ON palette_usage (workspace_id, item_id)
      """)

      execute("""
      CREATE INDEX IF NOT EXISTS palette_usage_workspace_id_last_used_at_desc_index
      ON palette_usage (workspace_id, last_used_at DESC)
      """)
    end
  end

  def down do
    drop_if_exists table(:palette_usage)
  end
end
