defmodule Casein.Agents.JidoWorkcell.ResourceStore do
  @moduledoc """
  Supervisor-owned Workcell resource catalog.

  The catalog is the durable-in-process read model for provisioning state: a
  cell may be torn down while its final stopped/rollback health remains
  inspectable. It intentionally stores only bounded, redacted metadata and no
  credentials or worker I/O. A future persistent scheduler can replace this
  adapter without changing the Cell or Jido pod contract.
  """

  use GenServer

  @name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put(opts, :name, @name))
  end

  @spec put(String.t(), map()) :: :ok
  def put(workcell_id, resource) when is_binary(workcell_id) and is_map(resource) do
    GenServer.call(@name, {:put, workcell_id, Map.put(resource, :workcell_id, workcell_id)})
  end

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
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:put, workcell_id, resource}, _from, state),
    do: {:reply, :ok, Map.put(state, workcell_id, resource)}

  def handle_call({:get, workcell_id}, _from, state),
    do: {:reply, Map.get(state, workcell_id), state}

  def handle_call(:list, _from, state),
    do: {:reply, state |> Map.values() |> Enum.sort_by(& &1.workcell_id), state}

  def handle_call({:delete, workcell_id}, _from, state),
    do: {:reply, :ok, Map.delete(state, workcell_id)}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{}}
end
