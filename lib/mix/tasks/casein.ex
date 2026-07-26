defmodule Mix.Tasks.Casein do
  use Boundary, classify_to: CaseinMix
  use Mix.Task

  @shortdoc "Lists the Casein task namespace"
  @moduledoc "Repository-local Casein task namespace."

  @impl Mix.Task
  def run(_args), do: Mix.Task.run("help", ["--search", "casein"])
end
