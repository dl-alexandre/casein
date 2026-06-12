defmodule PreviewCtl do
  @moduledoc """
  Generic preview control runtime for the BEAM.

  URL origin primitives, session registry, adapter behaviour, optional
  Playwright bridge, and runtime orchestration live here. DevIDE-specific
  Ecto persistence, audit, PubSub, and workspace surface resolution remain
  in `DevIDE.PreviewControl`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
