defmodule Casein.Supervision.Operator do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      [
        {Registry, keys: :unique, name: Casein.Operator.Registry},
        {DynamicSupervisor, name: Casein.Operator.SituationSupervisor, strategy: :one_for_one}
      ] ++ pg_probe()

    Supervisor.init(children, strategy: :one_for_one)
  end

  # The Postgres saturation probe shells out to psql every interval — started
  # only when explicitly enabled (DEV_IDE_PG_PROBE, see config/runtime.exs).
  defp pg_probe do
    if Application.get_env(:dev_ide, :pg_probe, false), do: [Casein.Ops.PgProbe], else: []
  end
end
