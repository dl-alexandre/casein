defmodule DevIde.Repo.Migrations.CreatePreviews do
  use Ecto.Migration

  def change do
    create table(:previews) do
      add :url, :string, null: false
      add :title, :string
      add :mode, :string, null: false, default: "tab"
      add :status, :string, null: false, default: "open"
      add :trusted, :boolean, null: false, default: false
      add :workspace_id, :binary_id, null: false
      add :session_id, :binary_id
      add :pane_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:previews, [:workspace_id])
    create index(:previews, [:workspace_id, :status])
    create index(:previews, [:session_id])
  end
end
