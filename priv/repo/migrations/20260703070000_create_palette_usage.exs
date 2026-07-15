defmodule DevIDE.Repo.Migrations.CreatePaletteUsage do
  use Ecto.Migration

  def change do
    create table(:palette_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :item_id, :string, null: false
      add :uses, :integer, null: false, default: 1
      add :last_used_at, :utc_datetime_usec, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:palette_usage, [:workspace_id, :item_id])
    create index(:palette_usage, [:workspace_id, "last_used_at desc"])
  end
end
