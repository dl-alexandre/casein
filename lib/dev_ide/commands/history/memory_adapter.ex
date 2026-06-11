defmodule DevIDE.Commands.History.MemoryAdapter do
  @moduledoc "In-memory adapter for `DevIDE.Commands.History`. Test/dev fallback."
  use GenServer
  @behaviour DevIDE.Commands.History

  alias DevIDE.Commands.History.Record

  @max_records 500

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl true
  def create(%Record{} = r), do: GenServer.call(__MODULE__, {:create, r})

  @impl true
  def update(id, attrs), do: GenServer.call(__MODULE__, {:update, id, attrs})

  @impl true
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @impl true
  def recent_for(workspace_id, limit),
    do: GenServer.call(__MODULE__, {:recent_for, workspace_id, limit})

  @impl true
  def list(opts), do: GenServer.call(__MODULE__, {:list, Keyword.get(opts, :limit, 100)})

  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_), do: {:ok, %{}}

  @impl GenServer
  def handle_call({:create, %Record{id: id} = r}, _from, state) do
    now = DateTime.utc_now()
    record = %{r | inserted_at: r.inserted_at || now, updated_at: now}
    state = Map.put(state, id, record) |> cap_records()
    {:reply, {:ok, record}, state}
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, existing} ->
        updated =
          existing
          |> Map.merge(
            Map.take(attrs, ~w(status exit_code output output_truncated finished_at duration_ms)a)
          )
          |> Map.put(
            :metadata,
            Map.merge(existing.metadata || %{}, Map.get(attrs, :metadata, %{}))
          )
          |> Map.put(:updated_at, DateTime.utc_now())

        {:reply, {:ok, updated}, Map.put(state, id, updated)}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state, id) do
      {:ok, r} -> {:reply, {:ok, r}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:recent_for, ws, n}, _from, state) do
    matches =
      state
      |> Map.values()
      |> Enum.filter(&(&1.workspace_id == ws))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(n)

    {:reply, matches, state}
  end

  def handle_call({:list, n}, _from, state) do
    list =
      state
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> Enum.take(n)

    {:reply, list, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  defp cap_records(state) do
    overflow = map_size(state) - @max_records

    if overflow > 0 do
      state
      |> Map.values()
      |> Enum.sort_by(& &1.started_at, DateTime)
      |> Enum.take(overflow)
      |> Enum.reduce(state, fn %{id: id}, acc -> Map.delete(acc, id) end)
    else
      state
    end
  end
end
