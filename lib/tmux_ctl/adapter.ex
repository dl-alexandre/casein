defmodule TmuxCtl.Adapter do
  @moduledoc """
  Behaviour for tmux session adapters used by topology reads and mutations.

  `TmuxCtl.Client` is the default implementation; tests swap in
  `TmuxCtl.Test.FakeAdapter` via application config.
  """

  @type session :: String.t()
  @type window_id :: String.t()
  @type pane_id :: String.t()

  @callback ensure_session(session(), String.t()) :: :ok | {:error, term()}

  @callback attach(session()) :: {:ok, port()} | {:error, term()}

  @callback send_keys(session(), String.t(), keyword()) :: :ok | {:error, term()}

  @callback list_session_windows(session()) :: [map()]

  @callback list_session_panes(session()) :: [map()]

  @callback session_topology(session()) :: {[map()], [map()]}

  @callback directory_inventory() :: {:ok, %{windows: map(), panes: map()}} | {:error, term()}

  @callback new_window(session(), keyword()) :: {:ok, window_id()} | {:error, term()}

  @callback select_window(session(), window_id()) :: :ok | {:error, term()}

  @callback cycle_window(session(), String.t()) :: :ok | {:error, term()}

  @callback select_pane(session(), pane_id()) :: :ok | {:error, term()}

  @callback navigate_pane(session(), String.t()) :: :ok | {:error, term()}

  @callback zoom_pane(session(), pane_id()) :: :ok | {:error, term()}

  @callback ensure_zoomed(session(), pane_id(), boolean()) :: :ok | {:error, term()}

  @callback kill_other_panes(session(), pane_id()) :: :ok | {:error, term()}

  @callback select_layout(session(), String.t()) :: :ok | {:error, term()}

  @callback next_layout(session()) :: :ok | {:error, term()}

  @callback kill_pane(session(), pane_id()) :: :ok | {:error, term()}

  @callback split_pane(session(), pane_id(), String.t(), keyword()) ::
              {:ok, pane_id()} | {:error, term()}

  @callback resize_pane(session(), pane_id(), String.t(), pos_integer() | nil) ::
              :ok | {:error, term()}

  @callback resize_amount_default() :: pos_integer()

  @callback resize_amount_max() :: pos_integer()

  @callback rename_window(session(), window_id(), String.t()) :: :ok | {:error, term()}

  @callback list_windows() :: [map()]

  @callback list_sessions() :: [map()]

  @callback list_panes() :: [map()]

  @callback kill_window(session(), window_id()) :: :ok | {:error, term()}

  @callback kill(session()) :: :ok | {:error, term()}

  @callback session_exists?(session()) :: boolean()

  @callback session_alive?(session()) :: boolean()

  @callback apply_defaults(session()) :: :ok | {:error, term()}

  @callback set_environment(session(), String.t(), String.t()) :: :ok | {:error, term()}

  @callback set_environments(session(), map()) :: :ok | {:error, term()}

  @callback send_command(session(), String.t(), keyword()) :: :ok | {:error, term()}

  @callback resize_window(session(), pos_integer(), pos_integer()) :: :ok | {:error, term()}

  @callback capture_scrollback(session(), keyword()) :: String.t()

  @callback tail_lines(String.t(), term()) :: String.t()
end
