defmodule Casein.Runtimes.LifecycleEventRow do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "runtime_lifecycle_events" do
    field :runtime_id, :string
    field :workspace_id, :string
    field :event, :string
    field :from_status, :string
    field :to_status, :string
    field :actor_id, :string
    field :assignment_id, :string
    field :runner_id, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime_usec
  end
end
