defmodule DevIDE.Test.ObanSignalsWorker do
  @moduledoc false

  use DevIDE.Signals.ObanWorker, queue: :default

  def execute(_job) do
    stamped = DevIDE.Signals.Context.stamp(%{action: "oban.worker"})
    Process.put({__MODULE__, :correlation_id}, stamped.metadata["correlation_id"])
    :ok
  end
end