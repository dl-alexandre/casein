defmodule DevIDE.Fleet.ArtifactStore do
  @moduledoc """
  Behaviour for append-only durable output/artifact records.

  ## Contract

    * `append_chunk/4` — store an output chunk durably
    * `chunks/1` — retrieve all chunks for an execution
    * `chunks_since/2` — retrieve chunks after a timestamp
    * `clear/0` — delete all artifacts (testing/development only)

  ## Design rules

    * Append-only — never mutate existing chunks
    * Keyed by execution_id
    * No assignment state mutation
    * RepoAdapter is the durable default; MemoryAdapter is for focused tests

  The projection is rebuildable from assignment events.
  Artifacts are durable records for replay and audit.
  """

  @type chunk :: DevIDE.Fleet.ArtifactStore.Adapter.chunk()

  @spec append_chunk(String.t(), String.t(), binary(), DateTime.t()) :: :ok | {:error, term()}
  def append_chunk(execution_id, stream, data, timestamp) do
    impl().append_chunk(execution_id, stream, data, timestamp)
  end

  @spec chunks(String.t()) :: [chunk()]
  def chunks(execution_id), do: impl().chunks(execution_id)

  @spec chunks_since(String.t(), DateTime.t()) :: [chunk()]
  def chunks_since(execution_id, since), do: impl().chunks_since(execution_id, since)

  @spec clear() :: :ok
  def clear, do: impl().clear()

  defp impl do
    Application.get_env(:dev_ide, :artifact_store_adapter, DevIDE.Fleet.ArtifactStore.RepoAdapter)
  end
end
