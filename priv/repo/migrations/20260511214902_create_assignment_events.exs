defmodule Casein.Repo.Migrations.CreateAssignmentEvents do
  use Ecto.Migration

  def change do
    create table(:assignment_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :assignment_id, :text, null: false
      add :sequence, :integer, null: false
      add :type, :text, null: false
      add :actor, :text
      add :payload, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec, null: false
    end

    create index(:assignment_events, [:assignment_id, :sequence],
             name: :assignment_events_assignment_id_sequence_idx
           )

    create index(:assignment_events, [:occurred_at])

    create unique_index(:assignment_events, [:assignment_id, :sequence],
             name: :assignment_events_assignment_id_sequence_uniq_idx
           )
  end
end
