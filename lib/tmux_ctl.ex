defmodule TmuxCtl do
  @moduledoc """
  Generic tmux control-plane client for the BEAM.

  Low-level subprocess I/O, topology parsing, and optional Phoenix PubSub
  watchers live here. DevIDE-specific naming, container argv wrapping, audit,
  and session GC remain in `DevIDE.Terminals.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
