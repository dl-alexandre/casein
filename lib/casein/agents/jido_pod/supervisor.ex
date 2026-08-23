defmodule Casein.Agents.JidoPod.Supervisor do
  @moduledoc false

  use Supervisor

  alias Casein.Agents.JidoPod.{Fleet, Metrics}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Metrics.ensure_table!()

    children = [
      {Registry, keys: :unique, name: Casein.Agents.JidoPod.Registry},
      {DynamicSupervisor, name: Casein.Agents.JidoPod.PodSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Casein.Agents.JidoPod.WorkerSupervisor, strategy: :one_for_one},
      Fleet
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
