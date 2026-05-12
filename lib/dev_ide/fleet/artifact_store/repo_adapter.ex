defmodule DevIDE.Fleet.ArtifactStore.RepoAdapter do
  @moduledoc """
  Postgres-backed adapter for `DevIDE.Fleet.ArtifactStore`.

  Execution output is stored as append-only chunks keyed by execution id.
  Sequences are assigned monotonically per execution so replay remains stable
  even when timestamps collide.
  """

  @behaviour DevIDE.Fleet.ArtifactStore

  alias DevIDE.Fleet.ArtifactStore.ChunkRow
  alias DevIde.Repo
  import Ecto.Query

  @impl DevIDE.Fleet.ArtifactStore
  def append_chunk(execution_id, stream, data, timestamp)
      when is_binary(execution_id) and is_binary(stream) and is_binary(data) do
    Repo.transaction(fn ->
      max_sequence =
        from(r in ChunkRow,
          where: r.execution_id == ^execution_id,
          select: max(r.sequence)
        )
        |> Repo.one()

      row =
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

      case row do
        {:ok, _inserted} -> :ok
        {:error, changeset} -> Repo.rollback(changeset_error(changeset))
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl DevIDE.Fleet.ArtifactStore
  def chunks(execution_id) when is_binary(execution_id) do
    from(r in ChunkRow,
      where: r.execution_id == ^execution_id,
      order_by: [asc: r.sequence]
    )
    |> Repo.all()
    |> Enum.map(&to_chunk/1)
  end

  @impl DevIDE.Fleet.ArtifactStore
  def chunks_since(execution_id, %DateTime{} = since) when is_binary(execution_id) do
    from(r in ChunkRow,
      where: r.execution_id == ^execution_id and r.timestamp >= ^since,
      order_by: [asc: r.sequence]
    )
    |> Repo.all()
    |> Enum.map(&to_chunk/1)
  end

  @impl DevIDE.Fleet.ArtifactStore
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
