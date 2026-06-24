defmodule DevIde.Repo.Migrations.CreatePreviewPaneRegistrations do
  use Ecto.Migration

  def change do
    create table(:preview_pane_registrations) do
      add :workspace_id, :string, null: false
      add :tmux_session, :string
      add :pane_id, :string, null: false
      add :preview_id, references(:previews, on_delete: :delete_all), null: false

      add :control_session_id, references(:preview_control_sessions, on_delete: :delete_all),
        null: false

      add :url, :string, null: false
      add :display_url, :string, null: false
      add :source_url, :string
      add :viewport, :map
      add :shared, :boolean, null: false, default: false
      add :source_pane_id, :string
      add :placement, :string
      add :anchor_pane_id, :string
      add :anchor_window_id, :string
      add :pane_window_id, :string
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create index(:preview_pane_registrations, [:workspace_id])
    create index(:preview_pane_registrations, [:workspace_id, :status])
    create index(:preview_pane_registrations, [:tmux_session])
    create index(:preview_pane_registrations, [:preview_id])
    create index(:preview_pane_registrations, [:control_session_id])
    create index(:preview_pane_registrations, [:source_pane_id])

    create unique_index(:preview_pane_registrations, [:pane_id],
             where: "status = 'open'",
             name: :preview_pane_registrations_open_pane_id_index
           )
  end
end
