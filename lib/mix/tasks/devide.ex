defmodule Mix.Tasks.Devide do
  @moduledoc """
  Boundary root for repository-local development Mix tasks.
  """

  use Boundary,
    deps: [Mix, Graph, Boxart],
    exports: :all
end
