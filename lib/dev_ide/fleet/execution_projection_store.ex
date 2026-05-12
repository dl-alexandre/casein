defmodule DevIDE.Fleet.ExecutionProjectionStore do
  @moduledoc """
  Disposable cache for execution projections.

  Builds projections by observing assignment events and protocol
  messages.  Not a source of truth — if the process restarts,
  projections can be rebuilt from the assignment event stream.

  ## Reduction rules

    * `AssignmentOffered` + `AssignmentAccepted` → create pending
    * `ExecutionStarted` → transition to :started
    * `ExecutionCompleted` → transition to :completed
    * `ExecutionFailed` → transition to :failed
    * `ExecutionAbandoned` → transition to :abandoned
    * `LeaseExpired` → transition to :expired
  """

  use GenServer

  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionStatus

  ## Public API

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Create a pending execution projection."
  @spec create(ExecutionProjection.t()) :: :ok
  def create(%ExecutionProjection{} = projection) do
    GenServer.call(__MODULE__, {:create, projection})
  end

  @doc "Get a projection by execution_id."
  @spec get(String.t()) :: {:ok, ExecutionProjection.t()} | :error
  def get(execution_id), do: GenServer.call(__MODULE__, {:get, execution_id})

  @doc "Update a projection's state and metadata."
  @spec update(String.t(), keyword()) :: :ok | :error
  def update(execution_id, attrs) do
    GenServer.call(__MODULE__, {:update, execution_id, attrs})
  end

  @doc "List all tracked projections."
  @spec list() :: [ExecutionProjection.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @doc "List projections for a given assignment."
  @spec for_assignment(String.t()) :: [ExecutionProjection.t()]
  def for_assignment(assignment_id) do
    GenServer.call(__MODULE__, {:for_assignment, assignment_id})
  end

  @doc "Find the active (most recent non-terminal) projection for an assignment."
  @spec active_for_assignment(String.t()) :: {:ok, ExecutionProjection.t()} | :error
  def active_for_assignment(assignment_id) do
    GenServer.call(__MODULE__, {:active_for_assignment, assignment_id})
  end

  @doc "Clear all projections."
  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  ## Callbacks

  @impl GenServer
  def init(_opts) do
    {:ok, %{projections: %{}}}
  end

  @impl GenServer
  def handle_call({:create, %ExecutionProjection{id: id} = projection}, _from, state) do
    {:reply, :ok, put_in(state, [:projections, id], projection)}
  end

  def handle_call({:get, id}, _from, state) do
    case Map.fetch(state.projections, id) do
      {:ok, p} -> {:reply, {:ok, p}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call({:update, id, attrs}, _from, state) do
    case Map.fetch(state.projections, id) do
      {:ok, projection} ->
        updated = struct!(projection, attrs)
        {:reply, :ok, put_in(state, [:projections, id], updated)}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state.projections), state}
  end

  def handle_call({:for_assignment, assignment_id}, _from, state) do
    results =
      state.projections
      |> Map.values()
      |> Enum.filter(&(&1.assignment_id == assignment_id))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})

    {:reply, results, state}
  end

  def handle_call({:active_for_assignment, assignment_id}, _from, state) do
    active =
      state.projections
      |> Map.values()
      |> Enum.filter(&(&1.assignment_id == assignment_id))
      |> Enum.reject(&ExecutionStatus.terminal?(&1.state))
      |> Enum.sort_by(& &1.started_at, {:desc, DateTime})
      |> List.first()

    if active do
      {:reply, {:ok, active}, state}
    else
      {:reply, :error, state}
    end
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{projections: %{}}}
  end
end
