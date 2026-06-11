defmodule DevIDE.Fleet.ArtifactStore.ChunkRow do
  @moduledoc "Ecto schema for durable fleet execution artifact chunks."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "fleet_artifact_chunks" do
    field :execution_id, :string
    field :sequence, :integer
    field :stream, :string
    field :data, :binary
    field :byte_size, :integer
    field :timestamp, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @doc false
  def changeset(row, attrs) do
    row
    |> cast(attrs, [:id, :execution_id, :sequence, :stream, :data, :byte_size, :timestamp])
    |> validate_required([:execution_id, :sequence, :stream, :data, :byte_size, :timestamp])
    |> validate_number(:sequence, greater_than: 0)
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> unique_constraint([:execution_id, :sequence],
      name: :fleet_artifact_chunks_execution_id_sequence_uniq_idx
    )
  end
end
