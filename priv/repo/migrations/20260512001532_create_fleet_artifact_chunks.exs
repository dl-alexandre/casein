defmodule DevIde.Repo.Migrations.CreateFleetArtifactChunks do
  use Ecto.Migration

  def change do
    create table(:fleet_artifact_chunks, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :execution_id, :text, null: false
      add :sequence, :integer, null: false
      add :stream, :text, null: false
      add :data, :binary, null: false
      add :byte_size, :integer, null: false
      add :timestamp, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:fleet_artifact_chunks, [:execution_id, :sequence],
             name: :fleet_artifact_chunks_execution_id_sequence_idx
           )

    create index(:fleet_artifact_chunks, [:execution_id, :timestamp],
             name: :fleet_artifact_chunks_execution_id_timestamp_idx
           )

    create unique_index(:fleet_artifact_chunks, [:execution_id, :sequence],
             name: :fleet_artifact_chunks_execution_id_sequence_uniq_idx
           )
  end
end
