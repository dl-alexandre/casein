defmodule DevIDE.Runners.AssignmentRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runner_assignments" do
    field :workspace_id, :string
    field :safe_action_id, :string
    field :safe_action_version, :integer
    field :status, :string
    field :requested_by, :string
    field :claimed_by, :string
    field :claim_token, :string
    field :queued_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :lease_expires_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :failure_reason, :string
    field :evidence, :map, default: %{}
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
