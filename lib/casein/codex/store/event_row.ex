defmodule Casein.Codex.Store.EventRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "codex_events" do
    field :workspace_id, :string
    field :runtime_id, :string
    field :transport, :string
    field :event_type, :string
    field :sequence, :integer
    field :occurred_at, :utc_datetime_usec
    field :thread_id, :string
    field :parent_thread_id, :string
    field :session_id, :string
    field :turn_id, :string
    field :item_id, :string
    field :tool_call_id, :string
    field :request_id, :string
    field :payload, :map, default: %{}
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime_usec)
  end
end
