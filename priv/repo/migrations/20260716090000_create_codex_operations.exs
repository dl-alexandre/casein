defmodule DevIDE.Repo.Migrations.CreateCodexOperations do
  use Ecto.Migration

  def change do
    create table(:codex_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :runtime_id, :string, null: false
      add :transport, :string, null: false
      add :event_type, :string, null: false
      add :sequence, :bigint, null: false
      add :occurred_at, :utc_datetime_usec, null: false
      add :thread_id, :string
      add :parent_thread_id, :string
      add :session_id, :string
      add :turn_id, :string
      add :item_id, :string
      add :tool_call_id, :string
      add :request_id, :string
      add :payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:codex_events, [:runtime_id, :sequence])
    create index(:codex_events, [:workspace_id, :occurred_at])
    create index(:codex_events, [:workspace_id, :thread_id, :occurred_at])
    create index(:codex_events, [:workspace_id, :event_type, :occurred_at])

    create table(:codex_threads, primary_key: false) do
      add :thread_id, :string, primary_key: true
      add :workspace_id, :string, null: false
      add :runtime_id, :string, null: false
      add :parent_thread_id, :string
      add :session_id, :string
      add :transport, :string, null: false
      add :status, :string
      add :active_flags, :map, null: false, default: %{}
      add :current_turn_id, :string
      add :agent_role, :string
      add :agent_nickname, :string
      add :preview, :string
      add :usage, :map, null: false, default: %{}
      add :last_sequence, :bigint, null: false
      add :last_event_at, :utc_datetime_usec, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:codex_threads, [:workspace_id, :last_event_at])
    create index(:codex_threads, [:workspace_id, :parent_thread_id])
    create index(:codex_threads, [:runtime_id, :last_event_at])

    create table(:codex_approvals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :workspace_id, :string, null: false
      add :runtime_id, :string, null: false
      add :thread_id, :string, null: false
      add :turn_id, :string
      add :item_id, :string
      add :request_id, :string
      add :kind, :string, null: false
      add :status, :string, null: false
      add :resolution, :map, null: false, default: %{}
      add :payload, :map, null: false, default: %{}
      add :metadata, :map, null: false, default: %{}
      add :requested_at, :utc_datetime_usec, null: false
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:codex_approvals, [:workspace_id, :status, :requested_at])
    create index(:codex_approvals, [:runtime_id, :status])
    create index(:codex_approvals, [:thread_id, :requested_at])
  end
end
