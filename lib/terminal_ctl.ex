defmodule TerminalCtl do
  @moduledoc """
  Generic terminal session primitives for the BEAM.

  Bounded replay buffers and PTY escape-sequence filtering live here.
  Casein-specific session owners, attachments, and audit remain in
  `Casein.Terminals.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
