defmodule DevIDE.Fleet.ArtifactStore.MemoryAdapter do
  @moduledoc """
  In-memory append-only artifact store.

  Used for focused tests.  Chunks are stored in an
  unbounded list per execution — this is acceptable because the
  memory adapter is explicitly ephemeral.
  """

  use GenServer

  @behaviour DevIDE.Fleet.ArtifactStore.Adapter

  ## Public API

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def append_chunk(execution_id, stream, data, timestamp) do
    GenServer.call(__MODULE__, {:append, execution_id, stream, data, timestamp})
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def chunks(execution_id) do
    GenServer.call(__MODULE__, {:chunks, execution_id})
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def chunks_since(execution_id, since) do
    GenServer.call(__MODULE__, {:chunks_since, execution_id, since})
  end

  @impl DevIDE.Fleet.ArtifactStore.Adapter
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:append, execution_id, stream, data, timestamp}, _from, state) do
    chunk = %{
      stream: stream,
      data: data,
      timestamp: timestamp,
      byte_size: byte_size(data)
    }

    chunks = Map.get(state, execution_id, [])
    state = Map.put(state, execution_id, chunks ++ [chunk])
    {:reply, :ok, state}
  end

  def handle_call({:chunks, execution_id}, _from, state) do
    {:reply, Map.get(state, execution_id, []), state}
  end

  def handle_call({:chunks_since, execution_id, since}, _from, state) do
    result =
      state
      |> Map.get(execution_id, [])
      |> Enum.filter(fn chunk ->
        DateTime.compare(chunk.timestamp, since) in [:gt, :eq]
      end)

    {:reply, result, state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{}}
  end
end
