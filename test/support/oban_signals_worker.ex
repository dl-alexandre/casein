defmodule Casein.Test.ObanSignalsWorker do
  @moduledoc false

  use Casein.Signals.ObanWorker, queue: :default

  @impl Casein.Signals.ObanWorker
  def execute(_job) do
    stamped = Casein.Signals.Context.stamp(%{action: "oban.worker"})
    Process.put({__MODULE__, :correlation_id}, stamped.metadata["correlation_id"])
    :ok
  end
end
