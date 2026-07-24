defmodule Casein.Repo.Migrations.AddTagsToSavedTemplates do
  use Ecto.Migration

  def change do
    alter table(:saved_templates) do
      add :tags, Casein.Repo.Adapter.list_storage_type(repo(), :text),
        null: false,
        default: Casein.Repo.Adapter.list_default(repo())
    end

    unless Casein.Repo.Adapter.sqlite?(repo()) do
      create index(:saved_templates, [:tags], using: :gin)
    end
  end
end
