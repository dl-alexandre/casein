defmodule DevIDE.Terminals.TmuxTopology do
  @moduledoc """
  Read-only tmux topology facade for workspace terminals.

  The LiveView should not know tmux format strings or error handling details.
  This module keeps the MVP intentionally small: one session, windows as tabs,
  and a version value that changes when the visible topology changes.
  """

  alias DevIDE.Terminals.Tmux

  @type window :: %{
          id: String.t(),
          index: non_neg_integer(),
          name: String.t(),
          active: boolean(),
          panes: pos_integer(),
          activity: non_neg_integer(),
          current_command: String.t()
        }

  @type t :: %{
          session: String.t(),
          windows: [window()],
          active_window_id: String.t() | nil,
          version: non_neg_integer()
        }

  @doc "Return the current window topology for a session."
  @spec get(String.t(), keyword()) :: t()
  def get(session, opts \\ []) when is_binary(session) do
    adapter = Keyword.get(opts, :tmux, tmux_adapter())
    windows = adapter.list_session_windows(session)
    active = Enum.find(windows, & &1.active)

    %{
      session: session,
      windows: windows,
      active_window_id: active && active.id,
      version: :erlang.phash2(windows)
    }
  end

  defp tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end
end
