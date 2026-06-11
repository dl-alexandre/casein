defmodule DevIDE.Fleet.ArtifactStore.RepoAdapter do
  @moduledoc """
  Postgres-backed adapter for `DevIDE.Fleet.ArtifactStore`.

  Execution output is stored as append-only chunks keyed by execution id.
  Sequences are assigned monotonically per execution so replay remains stable
  even when timestamps collide.
  """

  @behaviour DevIDE.Fleet.ArtifactStore.Adapter

  alias DevIDE.Fleet.ArtifactStore.ChunkRow
  alias DevIde.Repo
  import Ecto.Query

  # Concurrent appenders can read the same max(sequence); the unique index
  # rejects the loser, which recomputes and retries. (A plain transaction
  # does not prevent this at READ COMMITTED.)
  @max_append_attempts 5

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def append_chunk(execution_id, stream, data, timestamp)
      when is_binary(execution_id) and is_binary(stream) and is_binary(data) do
    do_append_chunk(execution_id, stream, data, timestamp, @max_append_attempts)
  end

  defp do_append_chunk(execution_id, stream, data, timestamp, attempts_left) do
    max_sequence =
      from(r in ChunkRow,
        where: r.execution_id == ^execution_id,
        select: max(r.sequence)
      )
      |> Repo.one()

    %ChunkRow{}
    |> ChunkRow.changeset(%{
      execution_id: execution_id,
      sequence: (max_sequence || 0) + 1,
      stream: stream,
      data: data,
      byte_size: byte_size(data),
      timestamp: timestamp
    })
    |> Repo.insert()
    |> case do
      {:ok, _inserted} ->
        :ok

      {:error, changeset} ->
        if sequence_conflict?(changeset) and attempts_left > 1 do
          do_append_chunk(execution_id, stream, data, timestamp, attempts_left - 1)
        else
          {:error, changeset_error(changeset)}
        end
    end
  end

  defp sequence_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> opts[:constraint] == :unique end)
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def chunks(execution_id) when is_binary(execution_id) do
    from(r in ChunkRow,
      where: r.execution_id == ^execution_id,
      order_by: [asc: r.sequence]
    )
    |> Repo.all()
    |> Enum.map(&to_chunk/1)
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def chunks_since(execution_id, %DateTime{} = since) when is_binary(execution_id) do
    from(r in ChunkRow,
      where: r.execution_id == ^execution_id and r.timestamp >= ^since,
      order_by: [asc: r.sequence]
    )
    |> Repo.all()
    |> Enum.map(&to_chunk/1)
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def clear do
    {_count, _} = Repo.delete_all(ChunkRow)
    :ok
  end

  defp to_chunk(%ChunkRow{} = row) do
    %{
      stream: row.stream,
      data: row.data,
      timestamp: row.timestamp,
      byte_size: row.byte_size
    }
  end

  defp changeset_error(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        to_string(Keyword.get(opts, String.to_existing_atom(key), key))
      end)
    end)
  end
end
