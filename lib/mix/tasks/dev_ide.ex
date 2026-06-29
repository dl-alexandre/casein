defmodule Mix.Tasks.DevIde do
  @moduledoc """
  Boundary root for project-specific Mix tasks.
  """

  use Boundary,
    top_level?: true,
    deps: [DevIDE],
    exports: :all
end
