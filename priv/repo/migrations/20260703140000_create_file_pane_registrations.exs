defmodule DevIde.Repo.Migrations.CreateFilePaneRegistrations do
  use Ecto.Migration

  def change do
    create table(:file_pane_registrations) do
      add :workspace_id, :string, null: false
      add :tmux_session, :string
      add :pane_id, :string, null: false
      add :pane_window_id, :string
      add :placement, :string
      add :anchor_pane_id, :string
      add :anchor_window_id, :string
      add :open_files, {:array, :map}, null: false, default: []
      add :active_path, :string
      add :status, :string, null: false, default: "open"

      timestamps(type: :utc_datetime)
    end

    create index(:file_pane_registrations, [:workspace_id])
    create index(:file_pane_registrations, [:workspace_id, :status])
    create index(:file_pane_registrations, [:tmux_session])

    create unique_index(:file_pane_registrations, [:pane_id],
             where: "status = 'open'",
             name: :file_pane_registrations_open_pane_id_index
           )
  end
end
