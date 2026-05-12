defmodule DevIDE.Fleet.OutputStream do
  @moduledoc """
  Ephemeral live execution output cache.

  OutputChunk, ArtifactChunk, and Telemetry messages are stored here
  for live display while execution is active.  They are **not**
  durable — `DevIDE.Fleet.ArtifactStore` owns the canonical output
  timeline.

  This store is a disposable operational cache.  If the process
  restarts, output is lost.  Reconnect semantics for operators
  will read from `ArtifactStore` first, then subscribe to live
  chunks.  Its sole purpose is to feed live views without blocking
  on artifact I/O.

  ## Design rules

    * Append-only per execution
    * Capped per stream (last 10_000 chunks)
    * Auto-pruned to 100 chunks when execution completes
    * No mutation of assignment state
    * Future durable replay comes from ArtifactStore, not this cache
  """

  use GenServer

  @default_max_chunks 10_000

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Append an output chunk for an execution."
  @spec append_chunk(String.t(), String.t(), String.t(), binary()) :: :ok
  def append_chunk(execution_id, stream, chunk, timestamp \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:append, execution_id, stream, chunk, timestamp})
  end

  @doc "Get all chunks for an execution, optionally filtered by stream."
  @spec chunks(String.t(), String.t() | nil) :: [map()]
  def chunks(execution_id, stream \\ nil) do
    GenServer.call(__MODULE__, {:chunks, execution_id, stream})
  end

  @doc "Get chunks for an execution since a given timestamp."
  @spec chunks_since(String.t(), DateTime.t()) :: [map()]
  def chunks_since(execution_id, since) do
    GenServer.call(__MODULE__, {:chunks_since, execution_id, since})
  end

  @doc "Get the last N chunks for an execution."
  @spec last_chunks(String.t(), non_neg_integer()) :: [map()]
  def last_chunks(execution_id, n \\ 100) do
    GenServer.call(__MODULE__, {:last_chunks, execution_id, n})
  end

  @doc "Register an execution stream (called when execution starts)."
  @spec register_execution(String.t()) :: :ok
  def register_execution(execution_id) do
    GenServer.call(__MODULE__, {:register, execution_id})
  end

  @doc "Prune a completed execution's stream (called after completion)."
  @spec prune_execution(String.t()) :: :ok
  def prune_execution(execution_id) do
    GenServer.call(__MODULE__, {:prune, execution_id})
  end

  @doc "Clear all streams."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{streams: %{}}}
  end

  @impl GenServer
  def handle_call({:append, execution_id, stream, chunk, timestamp}, _from, state) do
    entry = %{
      stream: stream,
      chunk: chunk,
      timestamp: timestamp,
      byte_size: byte_size(chunk)
    }

    streams =
      state.streams
      |> Map.put_new(execution_id, [])
      |> update_in([execution_id], fn existing ->
        [entry | existing] |> Enum.take(@default_max_chunks)
      end)

    {:reply, :ok, %{state | streams: streams}}
  end

  def handle_call({:chunks, execution_id, nil}, _from, state) do
    result =
      Map.get(state.streams, execution_id, [])
      |> Enum.reverse()

    {:reply, result, state}
  end

  def handle_call({:chunks, execution_id, stream}, _from, state) do
    result =
      state.streams
      |> Map.get(execution_id, [])
      |> Enum.filter(&(&1.stream == stream))
      |> Enum.reverse()

    {:reply, result, state}
  end

  def handle_call({:chunks_since, execution_id, since}, _from, state) do
    result =
      state.streams
      |> Map.get(execution_id, [])
      |> Enum.filter(fn entry ->
        DateTime.compare(entry.timestamp, since) in [:gt, :eq]
      end)
      |> Enum.reverse()

    {:reply, result, state}
  end

  def handle_call({:last_chunks, execution_id, n}, _from, state) do
    result =
      state.streams
      |> Map.get(execution_id, [])
      |> Enum.take(n)
      |> Enum.reverse()

    {:reply, result, state}
  end

  def handle_call({:register, execution_id}, _from, state) do
    {:reply, :ok, put_in(state, [:streams, execution_id], [])}
  end

  def handle_call({:prune, execution_id}, _from, state) do
    # Keep last 100 chunks for tail replay, drop the rest
    streams =
      Map.update(state.streams, execution_id, [], &Enum.take(&1, 100))

    {:reply, :ok, %{state | streams: streams}}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{streams: %{}}}
  end
end
