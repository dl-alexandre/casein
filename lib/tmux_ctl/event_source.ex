defmodule TmuxCtl.EventSource do
  @moduledoc """
  Push-event seam for tmux topology consumers.

  Watchers and session directories receive `{TmuxCtl.Events, ...}` tuples after
  a successful `subscribe/2`. Production uses `DevIDE.Terminals.TmuxEvents`;
  tests inject `TmuxCtl.Test.FakeEventSource`.

  When the source is unavailable (flag off, listener down, no server),
  `subscribe/2` returns `{:error, :unavailable}` and consumers stay on polling.
  """

  @callback subscribe(arg :: term(), subscriber :: pid()) ::
              {:ok, %{listener: pid(), connected?: boolean()}} | {:error, :unavailable}
end
