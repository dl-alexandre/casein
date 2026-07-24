defmodule GitCtl do
  @moduledoc """
  Generic git worktree inspection for the BEAM.

  Subprocess parsing and optional ETS caching live here. Casein workspace
  policy and adapter-based mutating git ops remain in `Casein.Git.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
