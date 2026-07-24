defmodule Casein.Repo.Migrations.AddRunnerProgressClientReportId do
  use Ecto.Migration

  def change do
    alter table(:runner_progress_reports) do
      add :client_report_id, :text
    end

    create unique_index(:runner_progress_reports, [:assignment_id, :client_report_id])
  end
end
