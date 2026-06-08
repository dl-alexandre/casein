defmodule DevIde.Repo.Migrations.CreateSavedTemplates do
  use Ecto.Migration

  def change do
    create table(:saved_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :text, null: false
      add :name, :text, null: false
      add :description, :text
      add :body, :map, null: false, default: %{}
      add :source_session, :text
      add :schema_version, :integer, null: false, default: 2
      timestamps(type: :utc_datetime_usec)
    end

    create index(:saved_templates, [:workspace_id])
    create index(:saved_templates, [:workspace_id, "inserted_at desc"])
    create index(:saved_templates, [:workspace_id, :name])
  end
end
