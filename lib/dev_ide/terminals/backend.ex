defmodule Casein.Terminals.Backend do
  @moduledoc """
  Product-level contract for durable terminal session engines.

  This describes sessions, windows, panes, input, output, and topology without
  requiring tmux. `Casein.Terminals.Tmux` is the current Unix implementation;
  a native Windows implementation can satisfy the same callbacks with ConPTY
  and its own session registry.
  """

  @type session_id :: String.t()
  @type window_id :: String.t()
  @type pane_id :: String.t()

  defmodule SpawnSpec do
    @moduledoc "Backend-owned instructions for starting a terminal transport."
    @enforce_keys [:command]
    defstruct [:command, exec_opts: []]

    @type t :: %__MODULE__{command: term(), exec_opts: keyword()}
  end

  @doc "Configured terminal backend module."
  @spec module() :: module()
  def module do
    Application.get_env(:casein, :terminal_backend) ||
      Casein.Terminals.Backends.Tmux
  end

  @callback session_name(String.t(), String.t()) :: session_id()
  @callback spawn_spec(term(), session_id()) :: {:ok, SpawnSpec.t()} | {:error, term()}
  @callback ensure_session(session_id(), Path.t()) :: :ok | {:error, term()}
  @callback attach(session_id()) :: {:ok, port()} | {:error, term()}
  @callback session_exists?(session_id()) :: boolean()
  @callback session_alive?(session_id()) :: boolean()
  @callback kill(session_id()) :: term()
  @callback send_keys(session_id(), String.t(), keyword()) :: term()
  @callback capture_recent(session_id(), pos_integer(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback capture_scrollback(session_id(), keyword()) :: String.t()
  @callback resize_window(session_id(), pos_integer(), pos_integer()) ::
              :ok | {:error, term()}
  @callback window_size(session_id()) ::
              {:ok, {pos_integer(), pos_integer()}} | {:error, term()}
  @callback list_session_windows(session_id()) :: [map()]
  @callback list_session_panes(session_id()) :: [map()]
  @callback session_topology(session_id()) :: {[map()], [map()]}
  @callback new_window(session_id(), keyword()) :: {:ok, window_id()} | {:error, term()}
  @callback select_window(session_id(), window_id()) :: :ok | {:error, term()}
  @callback kill_window(session_id(), window_id()) :: :ok | {:error, term()}
  @callback split_pane(session_id(), pane_id(), String.t(), keyword()) ::
              {:ok, pane_id()} | {:error, term()}
  @callback select_pane(session_id(), pane_id()) :: :ok | {:error, term()}
  @callback kill_pane(session_id(), pane_id()) :: :ok | {:error, term()}
  @callback resize_pane(session_id(), pane_id(), String.t(), pos_integer() | nil) ::
              :ok | {:error, term()}
  @callback set_pane_role(session_id(), pane_id(), String.t() | nil) ::
              :ok | {:error, term()}
end
