defmodule DevIde.Repo.Migrations.DropObanTables do
  use Ecto.Migration

  # Oban was removed — the supervisor, Pruner, and config were all wired up but
  # no `use Oban.Worker` ever shipped, so the polling process and tables did
  # nothing. Drop what `Oban.Migrations.up()` created. CASCADE clears dependent
  # indexes/triggers. IF EXISTS keeps this a no-op on databases that never ran
  # the create migration (fresh dev/CI). Irreversible: to bring Oban back, add a
  # fresh `Oban.Migrations.up()` migration.
  def up do
    execute("DROP TABLE IF EXISTS oban_jobs CASCADE")
    execute("DROP TABLE IF EXISTS oban_peers CASCADE")
    execute("DROP TYPE IF EXISTS oban_job_state CASCADE")
  end

  def down, do: :ok
end
