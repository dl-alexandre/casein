defmodule Casein.Repo.Migrations.CreateAnnotations do
  use Ecto.Migration

  def change do
    create table(:annotations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :text, null: false
      add :session_id, :text
      add :pane_id, :text
      add :preview_id, :binary_id

      add :content, :text, null: false
      add :author_type, :text, null: false
      add :visibility, :text, null: false, default: "shared"
      add :approval_state, :text, null: false, default: "approved"

      add :terminal_range, :map
      add :file_path, :text
      add :file_range, :map
      add :linked_entities, list_type(:map), null: false, default: list_default()
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:annotations, [:workspace_id, "inserted_at desc"])
    create index(:annotations, [:preview_id, "inserted_at desc"])
    create index(:annotations, [:session_id, "inserted_at desc"])
    create index(:annotations, [:file_path])
    create index(:annotations, [:approval_state, "inserted_at desc"])
  end

  defp list_type(inner_type), do: Casein.Repo.Adapter.list_storage_type(repo(), inner_type)
  defp list_default, do: Casein.Repo.Adapter.list_default(repo())
end
