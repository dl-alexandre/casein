defmodule Mix.Tasks.Jx.Runtimes do
  use Boundary, classify_to: DevIDE

  @moduledoc "Runtime orchestration CLI: mix jx.runtimes ls|show|expire|cleanup"
  use Mix.Task

  @shortdoc "Inspect and control DevIDE runtime records"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case DevIDE.CLI.Runtimes.run(args) do
      {:ok, output} ->
        Mix.shell().info(output)

      {:error, message} ->
        Mix.shell().error(message)
        exit({:shutdown, 1})
    end
  end
end
