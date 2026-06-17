defmodule GitCtl do
  @moduledoc """
  Generic git worktree inspection for the BEAM.

  Subprocess parsing and optional ETS caching live here. DevIDE workspace
  policy and adapter-based mutating git ops remain in `DevIDE.Git.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
