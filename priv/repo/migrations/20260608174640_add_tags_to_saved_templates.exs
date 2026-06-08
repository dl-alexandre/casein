defmodule DevIde.Repo.Migrations.AddTagsToSavedTemplates do
  use Ecto.Migration

  def change do
    alter table(:saved_templates) do
      add :tags, {:array, :text}, null: false, default: []
    end

    create index(:saved_templates, [:tags], using: :gin)
  end
end
