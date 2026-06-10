defmodule Mix.Tasks.Jx.Attach do
  use Boundary, classify_to: DevIDE

  @moduledoc """
  Replay and subscribe metadata for a fleet execution.

      mix jx.attach EXECUTION_ID
  """

  use Mix.Task

  @shortdoc "Inspect attach/reconnect data for an execution"

  @impl Mix.Task
  def run([execution_id]) do
    Mix.Task.run("app.start")

    case DevIDE.Fleet.Attach.packet(execution_id) do
      {:ok, packet} ->
        Mix.shell().info("execution: #{packet.execution.id}")
        Mix.shell().info("topic: #{packet.live_topic}")
        Mix.shell().info("chunks: #{length(packet.historical_chunks)}")
        Mix.shell().info("dossier workspace: #{packet.dossier.workspace_id}")

      {:error, reason} ->
        Mix.shell().error("attach failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  def run(_args) do
    Mix.shell().error("usage: mix jx.attach EXECUTION_ID")
    exit({:shutdown, 1})
  end
end
