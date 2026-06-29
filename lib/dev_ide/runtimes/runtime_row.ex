defmodule DevIDE.Runtimes.RuntimeRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "workspace_runtimes" do
    field :workspace_id, :string
    field :host_id, :string
    field :os, :string
    field :repo, :string
    field :branch, :string
    field :worktree_path, :string
    field :runner_id, :string
    field :session_id, :string
    field :tmux_session_id, :string
    field :isolation_mode, :string
    field :status, :string
    field :capabilities, DevIDE.EctoTypes.StringList, default: []
    field :tools, DevIDE.EctoTypes.StringList, default: []
    field :concurrency_limit, :integer, default: 1
    field :active_assignments, :integer, default: 0
    field :created_at, :utc_datetime_usec
    field :heartbeat_at, :utc_datetime_usec
    field :expired_at, :utc_datetime_usec
    field :cleaned_at, :utc_datetime_usec
    field :failure_reason, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
