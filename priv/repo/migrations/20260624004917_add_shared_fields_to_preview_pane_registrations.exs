defmodule Casein.Repo.Migrations.AddSharedFieldsToPreviewPaneRegistrations do
  use Ecto.Migration

  def up do
    unless Casein.Repo.Adapter.sqlite?(repo()) do
      alter table(:preview_pane_registrations) do
        add_if_not_exists :shared, :boolean, null: false, default: false
        add_if_not_exists :source_pane_id, :string
        add_if_not_exists :placement, :string
        add_if_not_exists :anchor_pane_id, :string
        add_if_not_exists :anchor_window_id, :string
        add_if_not_exists :pane_window_id, :string
      end
    end

    create_if_not_exists index(:preview_pane_registrations, [:source_pane_id])
  end

  def down do
    drop_if_exists index(:preview_pane_registrations, [:source_pane_id])

    unless Casein.Repo.Adapter.sqlite?(repo()) do
      alter table(:preview_pane_registrations) do
        remove_if_exists :pane_window_id, :string
        remove_if_exists :anchor_window_id, :string
        remove_if_exists :anchor_pane_id, :string
        remove_if_exists :placement, :string
        remove_if_exists :source_pane_id, :string
        remove_if_exists :shared, :boolean
      end
    end
  end
end
