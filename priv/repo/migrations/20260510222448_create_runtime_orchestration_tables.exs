defmodule DevIDE.Repo.Migrations.CreateRuntimeOrchestrationTables do
  use Ecto.Migration

  def change do
    create table(:runtime_hosts, primary_key: false) do
      add :id, :text, primary_key: true
      add :os, :text
      add :capabilities, list_type(:text), null: false, default: list_default()
      add :tools, list_type(:text), null: false, default: list_default()
      add :concurrency_limit, :integer, null: false, default: 1
      add :heartbeat_at, :utc_datetime_usec
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:runtime_hosts, [:os])
    create index(:runtime_hosts, ["heartbeat_at desc"])

    create table(:workspace_runtimes, primary_key: false) do
      add :id, :text, primary_key: true
      add :workspace_id, :text, null: false
      add :host_id, :text, null: false
      add :os, :text
      add :repo, :text
      add :branch, :text
      add :worktree_path, :text
      add :runner_id, :text
      add :session_id, :text
      add :tmux_session_id, :text
      add :isolation_mode, :text, null: false
      add :status, :text, null: false
      add :capabilities, list_type(:text), null: false, default: list_default()
      add :tools, list_type(:text), null: false, default: list_default()
      add :concurrency_limit, :integer, null: false, default: 1
      add :active_assignments, :integer, null: false, default: 0
      add :created_at, :utc_datetime_usec, null: false
      add :heartbeat_at, :utc_datetime_usec
      add :expired_at, :utc_datetime_usec
      add :cleaned_at, :utc_datetime_usec
      add :failure_reason, :text
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create index(:workspace_runtimes, [:workspace_id, :status])
    create index(:workspace_runtimes, [:host_id, :status])
    create index(:workspace_runtimes, [:repo, :branch])
    create index(:workspace_runtimes, [:isolation_mode])
    create index(:workspace_runtimes, ["heartbeat_at desc"])

    create table(:runtime_lifecycle_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :runtime_id,
          references(:workspace_runtimes, type: :text, on_delete: :delete_all),
          null: false

      add :workspace_id, :text, null: false
      add :event, :text, null: false
      add :from_status, :text
      add :to_status, :text, null: false
      add :actor_id, :text
      add :assignment_id, :text
      add :runner_id, :text
      add :metadata, :map, null: false, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:runtime_lifecycle_events, [:runtime_id, "inserted_at asc"])
    create index(:runtime_lifecycle_events, [:workspace_id, "inserted_at desc"])
    create index(:runtime_lifecycle_events, [:event, "inserted_at desc"])
  end

  defp list_type(inner_type), do: DevIDE.Repo.Adapter.list_storage_type(repo(), inner_type)
  defp list_default, do: DevIDE.Repo.Adapter.list_default(repo())
end
