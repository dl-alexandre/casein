defmodule DevIDE.Repo.Migrations.AddTagsToSavedTemplates do
  use Ecto.Migration

  def change do
    alter table(:saved_templates) do
      add :tags, DevIDE.Repo.Adapter.list_storage_type(repo(), :text),
        null: false,
        default: DevIDE.Repo.Adapter.list_default(repo())
    end

    unless DevIDE.Repo.Adapter.sqlite?(repo()) do
      create index(:saved_templates, [:tags], using: :gin)
    end
  end
end
