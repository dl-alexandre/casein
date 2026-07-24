defmodule PreviewCtl do
  @moduledoc """
  Generic preview control runtime for the BEAM.

  URL origin primitives, session registry, adapter behaviour, optional
  Playwright bridge, and runtime orchestration live here. Casein-specific
  Ecto persistence, audit, PubSub, and workspace surface resolution remain
  in `Casein.Previews.Control`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
