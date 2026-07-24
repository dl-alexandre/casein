defmodule Casein.Previews.ArtifactProtection do
  @moduledoc """
  Tracks preview artifact filenames currently displayed in panes so prune logic
  does not evict screenshots a viewer is still showing.
  """

  use GenServer

  @type workspace_id :: String.t()
  @type filename :: String.t()

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec protect(workspace_id(), filename()) :: :ok
  def protect(workspace_id, filename)
      when is_binary(workspace_id) and is_binary(filename) do
    GenServer.call(__MODULE__, {:protect, workspace_id, Path.basename(filename)})
  end

  @spec protected(workspace_id()) :: MapSet.t(filename())
  def protected(workspace_id) when is_binary(workspace_id) do
    GenServer.call(__MODULE__, {:protected, workspace_id})
  end

  @spec clear() :: :ok
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call({:protect, workspace_id, filename}, _from, state) do
    set =
      state
      |> Map.get(workspace_id, MapSet.new())
      |> MapSet.put(filename)

    {:reply, :ok, Map.put(state, workspace_id, set)}
  end

  def handle_call({:protected, workspace_id}, _from, state) do
    {:reply, Map.get(state, workspace_id, MapSet.new()), state}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}
end
