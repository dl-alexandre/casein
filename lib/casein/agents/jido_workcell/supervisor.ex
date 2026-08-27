defmodule Casein.Agents.JidoWorkcell.Supervisor do
  @moduledoc "Supervises Workcell cells, their resource catalog, and the handoff ledger."

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Casein.Agents.JidoWorkcell.Registry},
      {DynamicSupervisor,
       name: Casein.Agents.JidoWorkcell.CellSupervisor, strategy: :one_for_one},
      Casein.Agents.JidoWorkcell.ResourceStore,
      Casein.Agents.JidoWorkcell.Git.Ledger
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
