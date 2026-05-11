defmodule DevIDE.Elixir do
  @moduledoc "Public facade for lightweight Elixir/Phoenix navigation helpers."

  alias DevIDE.Elixir.{Symbols, Project, Tooling}

  defdelegate symbols(content, path), to: Symbols, as: :extract

  def project(root), do: Project.detect(root)
  def tooling(root), do: Tooling.detect(root)
end
