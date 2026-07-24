defmodule Casein.Repo.Migrations.DropLoopTables do
  use Ecto.Migration

  # The experimental self-improving Loops subsystem (Casein.Loops) was removed —
  # it was dormant (disabled by default, no generator configured, no caller, no
  # UI/MCP surface). Drop its tables. `down/0` recreates them to mirror
  # 20260620000000_create_loop_tables.exs so the migration is reversible.

  def up do
    drop table(:loop_attempts)
    drop table(:loop_runs)
  end

  def down do
    create table(:loop_runs) do
      add :workspace_id, :string
      add :target, :string, null: false
      add :status, :string, null: false, default: "running"
      add :max_rounds, :integer, null: false, default: 3
      add :converged, :boolean, null: false, default: false
      add :baseline_failures, {:array, :string}, null: false, default: []
      add :base_sha, :string
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:loop_runs, [:workspace_id])
    create index(:loop_runs, [:status])

    create table(:loop_attempts) do
      add :loop_run_id, references(:loop_runs, on_delete: :delete_all), null: false
      add :iteration, :integer, null: false
      add :diff, :text
      add :files_changed, {:array, :string}, null: false, default: []
      add :compile_ok, :boolean
      add :test_pass, :boolean
      add :holdout_pass, :boolean
      add :touched_test_files, :boolean
      add :added_rescue, :boolean
      add :new_failures, {:array, :string}, null: false, default: []
      add :score, :integer
      add :breakdown, :text
      add :verdict_legit, :boolean
      add :verdict_gamed, :boolean
      add :verdict_reason, :text
      add :feedback_in, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:loop_attempts, [:loop_run_id])
    create unique_index(:loop_attempts, [:loop_run_id, :iteration])
  end
end
