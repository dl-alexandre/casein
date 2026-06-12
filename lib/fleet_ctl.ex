defmodule FleetCtl do
  @moduledoc """
  Generic fleet protocol primitives for the BEAM.

  `FleetCtl.Protocol.Envelope` and `FleetCtl.Protocol.Messages` provide the
  versioned controller ↔ runner wire contract. Envelope field validation
  helpers live in `FleetCtl.Envelope`. Lease-aware transition validation and
  DevIDE fleet state remain in `DevIDE.Fleet.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
