defmodule DevIDE.Fleet.OutputStream do
  @moduledoc """
  Ephemeral live execution output cache.

  OutputChunk, ArtifactChunk, and Telemetry messages are stored here
  for live display while execution is active.  They are **not**
  durable — `DevIDE.Fleet.ArtifactStore` owns the canonical output
  timeline.

  This store is a disposable operational cache backed by public ETS
  tables.  If the node restarts, output is lost.  Reconnect semantics
  for operators will read from `ArtifactStore` first, then subscribe
  to live chunks.  Its sole purpose is to feed live views without
  blocking on artifact I/O.

  ## Design rules

    * Append-only per execution (direct ETS insert — no GenServer on hot path)
    * Capped per stream (last 10_000 chunks)
    * Auto-pruned to 100 chunks when execution completes
    * No mutation of assignment state
    * Future durable replay comes from ArtifactStore, not this cache
  """

  @chunks_table :dev_ide_output_stream_chunks
  @meta_table :dev_ide_output_stream_meta
  @default_max_chunks 10_000
  @prune_keep_chunks 100

  ## Public API

  @doc false
  def ensure_table! do
    access = Application.get_env(:dev_ide, :ets_table_access, :protected)

    case :ets.whereis(@chunks_table) do
      :undefined ->
        :ets.new(@chunks_table, [:named_table, access, :ordered_set])

      _ ->
        :ok
    end

    case :ets.whereis(@meta_table) do
      :undefined ->
        :ets.new(@meta_table, [:named_table, access, :set])

      _ ->
        :ok
    end

    :ok
  end

  @doc "Append an output chunk for an execution."
  @spec append_chunk(String.t(), String.t(), String.t(), binary(), keyword()) :: :ok
  def append_chunk(execution_id, stream, chunk, timestamp \\ DateTime.utc_now(), opts \\ []) do
    ensure_table!()

    ordinal =
      :ets.update_counter(@meta_table, execution_id, {2, 1}, {execution_id, 0, 0})

    entry = %{
      stream: stream,
      chunk: chunk,
      seq: Keyword.get(opts || [], :seq),
      timestamp: timestamp,
      byte_size: byte_size(chunk)
    }

    :ets.insert(@chunks_table, {{execution_id, ordinal}, entry})

    count = :ets.update_counter(@meta_table, execution_id, {3, 1})
    trim_if_over_cap(execution_id, count, max_chunks())

    :ok
  end

  @doc "Get all chunks for an execution, optionally filtered by stream."
  @spec chunks(String.t(), String.t() | nil) :: [map()]
  def chunks(execution_id, stream \\ nil) do
    ensure_table!()

    execution_id
    |> list_entries()
    |> maybe_filter_stream(stream)
    |> entry_values()
  end

  @doc "Get chunks for an execution since a given timestamp."
  @spec chunks_since(String.t(), DateTime.t()) :: [map()]
  def chunks_since(execution_id, since) do
    ensure_table!()

    execution_id
    |> list_entries()
    |> Enum.filter(fn {_key, entry} ->
      DateTime.compare(entry.timestamp, since) in [:gt, :eq]
    end)
    |> entry_values()
  end

  @doc "Get the last N chunks for an execution."
  @spec last_chunks(String.t(), non_neg_integer()) :: [map()]
  def last_chunks(execution_id, n \\ 100) do
    ensure_table!()

    execution_id
    |> list_entries()
    |> Enum.take(-n)
    |> entry_values()
  end

  @doc "Register an execution stream (called when execution starts)."
  @spec register_execution(String.t()) :: :ok
  def register_execution(execution_id) do
    ensure_table!()
    delete_chunks_for_execution(execution_id)
    :ets.insert(@meta_table, {execution_id, 0, 0})
    :ok
  end

  @doc "Prune a completed execution's stream (called after completion)."
  @spec prune_execution(String.t()) :: :ok
  def prune_execution(execution_id) do
    ensure_table!()

    entries = list_entries(execution_id)
    keep = @prune_keep_chunks

    if length(entries) > keep do
      {to_delete, remaining} = Enum.split(entries, length(entries) - keep)
      Enum.each(to_delete, &:ets.delete_object(@chunks_table, &1))
      sync_meta_after_prune(execution_id, remaining)
    end

    :ok
  end

  @doc "Clear all streams."
  @spec clear() :: :ok
  def clear do
    ensure_table!()
    :ets.delete_all_objects(@chunks_table)
    :ets.delete_all_objects(@meta_table)
    :ok
  end

  ## Internal

  defp list_entries(execution_id) do
    @chunks_table
    |> :ets.match_object({{execution_id, :_}, :_})
    |> Enum.sort_by(fn {{_id, ordinal}, _entry} -> ordinal end)
  end

  defp maybe_filter_stream(entries, nil), do: entries

  defp maybe_filter_stream(entries, stream) do
    Enum.filter(entries, fn {_key, entry} -> entry.stream == stream end)
  end

  defp entry_values(entries), do: Enum.map(entries, fn {_key, entry} -> entry end)

  defp trim_if_over_cap(_execution_id, count, max) when count <= max, do: :ok

  defp trim_if_over_cap(execution_id, count, max) do
    to_delete = count - max
    entries = list_entries(execution_id)

    Enum.take(entries, to_delete)
    |> Enum.each(&:ets.delete_object(@chunks_table, &1))

    :ets.update_counter(@meta_table, execution_id, {3, -to_delete})
    :ok
  end

  defp delete_chunks_for_execution(execution_id) do
    :ets.match_delete(@chunks_table, {{execution_id, :_}, :_})
  end

  defp sync_meta_after_prune(execution_id, remaining) do
    {next_ord, count} =
      case remaining do
        [] ->
          {0, 0}

        _ ->
          ordinals = Enum.map(remaining, fn {{_id, ordinal}, _entry} -> ordinal end)
          {Enum.max(ordinals), length(remaining)}
      end

    :ets.insert(@meta_table, {execution_id, next_ord, count})
  end

  defp max_chunks do
    Application.get_env(:dev_ide, :output_stream_max_chunks, @default_max_chunks)
  end
end
