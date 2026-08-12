defmodule Casein.Terminals.Backend do
  @moduledoc """
  Product-level contract for durable terminal session engines.

  This describes sessions, windows, panes, input, output, and topology without
  requiring tmux. `Casein.Terminals.Backends.Tmux` is the current Unix
  implementation; a native Windows peer (`Backends.ConPTY`) satisfies the same
  callbacks with ConPTY and its own session registry.

  ## Surface alignment (#896)

  Every callback on `TmuxCtl.Adapter` is also a Backend callback (same name and
  arity). Product-only callbacks (`session_name/2`, `spawn_spec/2`,
  `window_size/1`) stay Backend-only — they are naming/spawn policy, not
  swappable adapter ops.

  The contract list is **not** hand-maintained for the adapter half: tests
  derive it from `TmuxCtl.Adapter.behaviour_info(:callbacks)` so a new adapter
  function cannot ship without Backend + Fake implementing it. That is the
  compile/test twin of the #854 outage class (`mcp_self_test` is the runtime twin).
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

  @doc """
  Unique `TmuxCtl.Adapter` callbacks — the adapter half of the Backend surface.

  Derived programmatically so the list cannot drift from the adapter behaviour.
  """
  @spec adapter_callbacks() :: [{atom(), arity()}]
  def adapter_callbacks do
    TmuxCtl.Adapter.behaviour_info(:callbacks)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Product-only Backend callbacks that are not on `TmuxCtl.Adapter`.

  Naming, spawn policy, and window-size query live here because they are not
  part of the swappable low-level adapter contract.
  """
  @spec product_only_callbacks() :: [{atom(), arity()}]
  def product_only_callbacks do
    [
      {:session_name, 2},
      {:spawn_spec, 2},
      {:window_size, 1}
    ]
  end

  @doc "Full Backend surface: adapter callbacks ∪ product-only callbacks."
  @spec required_callbacks() :: [{atom(), arity()}]
  def required_callbacks do
    (adapter_callbacks() ++ product_only_callbacks())
    |> Enum.uniq()
    |> Enum.sort()
  end

  # --- Product-only ----------------------------------------------------------

  @callback session_name(String.t(), String.t()) :: session_id()
  @callback spawn_spec(term(), session_id()) :: {:ok, SpawnSpec.t()} | {:error, term()}
  @callback window_size(session_id()) ::
              {:ok, {pos_integer(), pos_integer()}} | {:error, term()}

  # --- Session lifecycle (shared with TmuxCtl.Adapter) -----------------------

  @callback ensure_session(session_id(), Path.t()) :: :ok | {:error, term()}
  @callback attach(session_id()) :: {:ok, port() | term()} | {:error, term()}
  @callback session_exists?(session_id()) :: boolean()
  @callback session_alive?(session_id()) :: boolean()
  @callback kill(session_id()) :: term()
  @callback apply_defaults(session_id()) :: :ok | {:error, term()}
  @callback list_sessions() :: [map()]

  # --- Input / output --------------------------------------------------------

  @callback send_keys(session_id(), String.t(), keyword()) :: :ok | {:error, term()} | term()
  @callback send_command(session_id(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback paste_text(session_id(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback inject(session_id(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback capture_recent(session_id(), pos_integer(), keyword()) ::
              {:ok, String.t()} | {:error, term()}
  @callback capture_scrollback(session_id(), keyword()) :: String.t()
  @callback tail_lines(String.t(), term()) :: String.t()

  # --- Topology --------------------------------------------------------------

  @callback list_session_windows(session_id()) :: [map()]
  @callback list_session_panes(session_id()) :: [map()]
  @callback session_topology(session_id()) :: {[map()], [map()]}
  @callback directory_inventory() :: {:ok, %{windows: map(), panes: map()}} | :error
  @callback list_windows() :: [map()]
  @callback list_panes() :: [map()]

  # --- Windows ---------------------------------------------------------------

  @callback new_window(session_id(), keyword()) :: {:ok, window_id()} | {:error, term()}
  @callback select_window(session_id(), window_id()) :: :ok | {:error, term()}
  @callback kill_window(session_id(), window_id()) :: :ok | {:error, term()}
  @callback last_window(session_id()) :: :ok | {:error, term()}
  @callback cycle_window(session_id(), String.t()) :: :ok | {:error, term()}
  @callback consolidate_sessions(session_id(), [session_id()]) :: {:ok, map()} | {:error, term()}
  @callback rename_window(session_id(), window_id(), String.t()) :: :ok | {:error, term()}
  @callback set_session_alias(session_id(), String.t()) :: :ok | {:error, term()}
  @callback resize_window(session_id(), pos_integer(), pos_integer()) ::
              :ok | {:error, term()}
  @callback refresh_client(session_id()) :: :ok | {:error, term()}

  # --- Panes -----------------------------------------------------------------

  @callback split_pane(session_id(), pane_id(), String.t(), keyword()) ::
              {:ok, pane_id()} | {:error, term()}
  @callback select_pane(session_id(), pane_id()) :: :ok | {:error, term()}
  @callback kill_pane(session_id(), pane_id()) :: :ok | {:error, term()}
  @callback resize_pane(session_id(), pane_id(), String.t(), pos_integer() | nil) ::
              :ok | {:error, term()}
  @callback set_pane_role(session_id(), pane_id(), String.t() | nil) ::
              :ok | {:error, term()}
  @callback navigate_pane(session_id(), String.t()) :: :ok | {:error, term()}
  @callback zoom_pane(session_id(), pane_id()) :: :ok | {:error, term()}
  @callback swap_pane(session_id(), pane_id(), String.t()) :: :ok | {:error, term()}
  @callback ensure_zoomed(session_id(), pane_id(), boolean()) :: :ok | {:error, term()}
  @callback kill_other_panes(session_id(), pane_id()) :: :ok | {:error, term()}
  @callback select_layout(session_id(), String.t()) :: :ok | {:error, term()}
  @callback next_layout(session_id()) :: :ok | {:error, term()}
  @callback resize_amount_default() :: pos_integer()
  @callback resize_amount_max() :: pos_integer()

  # --- Environment / server --------------------------------------------------

  @callback set_environment(session_id(), String.t(), String.t()) :: :ok | {:error, term()}
  @callback set_environments(session_id(), map()) :: :ok | {:error, term()}
  @callback server_version() :: {non_neg_integer(), non_neg_integer()} | nil
end
