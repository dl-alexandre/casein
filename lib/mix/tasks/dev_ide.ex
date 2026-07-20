defmodule Mix.Tasks.DevIde do
  use Boundary, classify_to: DevIDEMix
  use Mix.Task

  @shortdoc "Lists the DevIDE task namespace"
  @moduledoc "Repository-local DevIDE task namespace."

  @impl Mix.Task
  def run(_args), do: Mix.Task.run("help", ["--search", "dev_ide"])
end
