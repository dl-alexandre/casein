defmodule DevIDE.Assignments.ProjectionStore.MemoryAdapter do
  @moduledoc "In-memory projection cache for assignments."

  use GenServer

  @behaviour DevIDE.Assignments.ProjectionStore

  alias DevIDE.Assignments.Assignment

  ## API

  def start_link(_opts \\ []),
    do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @impl DevIDE.Assignments.ProjectionStore
  def put(id, %Assignment{} = projection),
    do: GenServer.call(__MODULE__, {:put, id, projection})

  @impl DevIDE.Assignments.ProjectionStore
  def get(id), do: GenServer.call(__MODULE__, {:get, id})

  @impl DevIDE.Assignments.ProjectionStore
  def list(opts \\ []), do: GenServer.call(__MODULE__, {:list, opts})

  @impl DevIDE.Assignments.ProjectionStore
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_), do: {:ok, %{projections: %{}}}

  @impl GenServer
  def handle_call({:put, id, %Assignment{} = p}, _from, state) do
    {:reply, :ok, put_in(state, [:projections, id], p)}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.projections, id) do
      {:ok, p} -> {:reply, {:ok, p}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:list, opts}, _from, state) do
    results =
      state.projections
      |> Map.values()
      |> filter_opts(opts)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    {:reply, results, state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{projections: %{}}}

  ## Internal

  defp filter_opts(assignments, []), do: assignments

  defp filter_opts(assignments, [{:workspace_id, ws_id} | rest]) do
    assignments
    |> Enum.filter(&(&1.workspace_id == ws_id))
    |> filter_opts(rest)
  end

  defp filter_opts(assignments, [{:state, state} | rest]) do
    assignments
    |> Enum.filter(&(&1.state == state))
    |> filter_opts(rest)
  end

  defp filter_opts(assignments, [{:run_id, run_id} | rest]) do
    assignments
    |> Enum.filter(&(&1.run_id == run_id))
    |> filter_opts(rest)
  end

  defp filter_opts(assignments, [_ | rest]), do: filter_opts(assignments, rest)
end
