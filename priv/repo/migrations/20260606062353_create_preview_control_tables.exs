defmodule DevIDE.Repo.Migrations.CreatePreviewControlTables do
  use Ecto.Migration

  def change do
    create table(:preview_control_sessions) do
      add :workspace_id, :string, null: false
      add :preview_id, references(:previews, on_delete: :nilify_all)
      add :surface, :string, null: false
      add :adapter, :string, null: false
      add :status, :string, null: false, default: "open"
      add :current_url, :string
      add :actor_id, :string
      add :assignment_id, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:preview_control_sessions, [:workspace_id])
    create index(:preview_control_sessions, [:workspace_id, :status])
    create index(:preview_control_sessions, [:preview_id])

    create table(:preview_actions) do
      add :session_id, references(:preview_control_sessions, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :params, :map, null: false, default: %{}
      add :result, :map, null: false, default: %{}
      add :status, :string, null: false, default: "ok"
      add :actor_id, :string
      add :assignment_id, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:preview_actions, [:session_id])

    create table(:preview_observations) do
      add :session_id, references(:preview_control_sessions, on_delete: :delete_all), null: false
      add :action_id, references(:preview_actions, on_delete: :nilify_all)
      add :kind, :string, null: false
      add :data, :map, null: false, default: %{}
      add :artifact_path, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:preview_observations, [:session_id])
    create index(:preview_observations, [:session_id, :kind])
  end
end
