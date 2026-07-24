defmodule Casein.Codex.Store.ApprovalRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "codex_approvals" do
    field :workspace_id, :string
    field :runtime_id, :string
    field :thread_id, :string
    field :turn_id, :string
    field :item_id, :string
    field :request_id, :string
    field :kind, :string
    field :status, :string
    field :resolution, :map, default: %{}
    field :payload, :map, default: %{}
    field :metadata, :map, default: %{}
    field :requested_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
