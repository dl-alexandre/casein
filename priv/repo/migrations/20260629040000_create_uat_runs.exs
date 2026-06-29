defmodule DevIde.Repo.Migrations.CreateUatRuns do
  use Ecto.Migration

  def change do
    create table(:uat_runs) do
      add :scenario_id, :string, null: false
      add :tier, :string, null: false
      add :target_instance, :string
      # ControlSession id the run drove. Intentionally not a FK: a Tier B run
      # targets a session on the live release node, possibly a different
      # instance than the one persisting this row.
      add :session_id, :integer
      add :outcome, :string
      add :verdict, :map, null: false, default: %{}
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # Composite [:scenario_id, :inserted_at] also serves scenario_id-prefix queries.
    create index(:uat_runs, [:scenario_id, :inserted_at])
    create index(:uat_runs, [:outcome])
  end
end
