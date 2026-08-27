defmodule Casein.Agents.JidoWorkcell.ResourceStore do
  @moduledoc """
  Supervisor-owned Workcell resource catalog.

  The catalog is a read-through cache over the V3 runtime persistence boundary.
  A cell may be torn down while its final stopped/rollback health remains
  inspectable, and the projection is reloaded and reconciled on application
  startup. It intentionally stores only bounded, redacted metadata and no
  credentials or worker I/O.
  """

  use GenServer

  alias Casein.Agents.JidoWorkcell.ResourcePersistence

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, @name))
  end

  @spec put(String.t(), map()) :: :ok
  def put(workcell_id, resource) when is_binary(workcell_id) and is_map(resource) do
    GenServer.call(@name, {:put, workcell_id, Map.put(resource, :workcell_id, workcell_id)})
  end

  @doc "Persist one successful, redacted handoff result for replay after restart."
  @spec record_idempotency(String.t(), map()) :: :ok
  def record_idempotency(workcell_id, entry) when is_binary(workcell_id) and is_map(entry) do
    GenServer.call(@name, {:record_idempotency, workcell_id, entry})
  end

  @doc "Reload the V3 projection and reconcile process-owned state as stale."
  @spec recover() :: :ok
  def recover, do: GenServer.call(@name, :recover)

  @spec get(String.t()) :: map() | nil
  def get(workcell_id) when is_binary(workcell_id), do: GenServer.call(@name, {:get, workcell_id})

  @spec list() :: [map()]
  def list, do: GenServer.call(@name, :list)

  @spec delete(String.t()) :: :ok
  def delete(workcell_id) when is_binary(workcell_id),
    do: GenServer.call(@name, {:delete, workcell_id})

  @doc "Test-only reset; the application never calls this during normal operation."
  @spec reset() :: :ok
  def reset, do: GenServer.call(@name, :reset)

  @impl true
  def init(_opts), do: {:ok, load_resources()}

  @impl true
  def handle_call({:put, workcell_id, resource}, _from, state) do
    resource = ResourcePersistence.merge(Map.get(state, workcell_id), resource)
    _ = ResourcePersistence.put(resource)
    {:reply, :ok, Map.put(state, workcell_id, resource)}
  end

  def handle_call({:record_idempotency, workcell_id, entry}, _from, state) do
    case Map.get(state, workcell_id) do
      resource when is_map(resource) ->
        resource = ResourcePersistence.add_idempotency(resource, entry)
        _ = ResourcePersistence.put(resource)
        {:reply, :ok, Map.put(state, workcell_id, resource)}

      nil ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:get, workcell_id}, _from, state),
    do: {:reply, Map.get(state, workcell_id), state}

  def handle_call(:list, _from, state),
    do: {:reply, state |> Map.values() |> Enum.sort_by(& &1.workcell_id), state}

  def handle_call({:delete, workcell_id}, _from, state),
    do: {:reply, :ok, Map.delete(state, workcell_id)}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}

  def handle_call(:recover, _from, _state) do
    {:reply, :ok, load_resources()}
  end

  defp load_resources do
    ResourcePersistence.list()
    |> Enum.map(fn resource ->
      reconciled = ResourcePersistence.reconcile(resource)
      if reconciled != resource, do: ResourcePersistence.put(reconciled)
      reconciled
    end)
    |> Map.new(fn resource -> {resource.workcell_id, resource} end)
  end
end
