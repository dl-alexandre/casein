defmodule FleetCtl do
  @moduledoc """
  Generic fleet protocol primitives for the BEAM.

  Envelope field validation helpers live here. Lease-aware transition
  validation and DevIDE fleet state remain in `DevIDE.Fleet.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
