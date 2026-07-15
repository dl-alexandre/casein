defmodule DevIDE.Repo.Migrations.IndexWorkspaceRecordsHostPath do
  use Ecto.Migration

  # Non-unique on purpose: a manager record and a folder-attach record can
  # legitimately share a host_path; PathResolver picks the preferred one.
  def change do
    create index(:workspace_records, [:host_path], where: "host_path IS NOT NULL")
  end
end
