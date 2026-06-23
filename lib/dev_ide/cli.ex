defmodule DevIDE.CLI do
  @moduledoc "Small command dispatcher for DevIDE-owned operator surfaces."

  alias DevIDE.CLI.Runtimes

  def run(["runtimes" | args]), do: Runtimes.run(args)
  def run(_), do: {:error, "usage: jx runtimes ls|show|expire|cleanup"}
end
