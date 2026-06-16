defmodule ExecCtl do
  @moduledoc """
  Generic OS process execution primitives for the BEAM.

  erlexec streaming and static command allowlists live here. DevIDE audit,
  workspace policy, and adapter-specific argv building remain in `DevIDE.Commands.*`.
  """

  use Boundary,
    deps: [],
    exports: :all
end
