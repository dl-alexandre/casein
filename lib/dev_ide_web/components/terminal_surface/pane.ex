defmodule DevIdeWeb.TerminalSurface.Pane do
  @moduledoc """
  Minimal pane data needed by `DevIdeWeb.TerminalSurface`.

  WorkspaceLive owns workers, session ids, backend selection, and lifecycle
  metadata. The terminal surface only needs enough data to render a Ghostty
  terminal, loading state, or retryable error.
  """

  @type t :: %__MODULE__{
          term: pid() | nil,
          pty: pid() | nil,
          error: term() | nil,
          session_sid: String.t() | nil
        }

  defstruct term: nil, pty: nil, error: nil, session_sid: nil
end
