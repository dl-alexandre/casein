defmodule DevIDE.Terminals.TmuxOps do
  @moduledoc false

  alias DevIDE.Terminals.{
    CleanExec,
    Shims,
    Theme,
    Tmux,
    TmuxJanitor,
    TmuxRunner,
    TmuxScope,
    TmuxServer,
    TmuxTopology,
    ToolThemes
  }

  @doc "Configured platform terminal backend."
  @spec backend() :: module()
  def backend, do: DevIDE.Terminals.Backend.module()

  @doc "Configured tmux-compatible adapter during the platform migration."
  @spec tmux_adapter() :: module()
  def tmux_adapter do
    Application.get_env(:dev_ide, :tmux_adapter, Tmux)
  end

  @doc "Best-effort tmux server version as `{major, minor}`, or `nil` if unknown."
  @spec tmux_version() :: {non_neg_integer(), non_neg_integer()} | nil
  def tmux_version, do: tmux_adapter().server_version()

  @doc "True when terminal tmux commands run directly on the host."
  @spec tmux_host_shell?() :: boolean()
  def tmux_host_shell? do
    Tmux.host_shell?()
  end

  @doc "True when local tmux command argv is wrapped into a workspace target."
  @spec tmux_local_argv_wrapped?() :: boolean()
  def tmux_local_argv_wrapped? do
    Tmux.local_argv_wrapped?()
  end

  @doc "True when the workspace container can run tmux."
  @spec tmux_container_has_tmux?(String.t()) :: boolean()
  def tmux_container_has_tmux?(cwd) do
    Tmux.container_has_tmux?(cwd)
  end

  @doc "Tmux server arguments for host-targeted terminal invocations."
  @spec tmux_server_args() :: [String.t()]
  def tmux_server_args do
    TmuxServer.args()
  end

  @doc "Host tmux argv for terminal invocations, including DevIDE server label and config."
  @spec tmux_host_argv([String.t()]) :: [String.t()]
  def tmux_host_argv(args) when is_list(args) do
    TmuxRunner.host_argv(args)
  end

  @doc "Wraps a terminal argv with the configured clean execution environment."
  @spec clean_terminal_argv([String.t()]) :: [String.t()]
  def clean_terminal_argv(argv) do
    CleanExec.wrap_argv(argv)
  end

  @doc "Environment flags for tmux commands that create terminal panes or windows."
  @spec terminal_shim_tmux_env_flags(keyword()) :: [String.t()]
  def terminal_shim_tmux_env_flags(opts \\ []) do
    Shims.tmux_env_flags(opts)
  end

  @doc "Environment assignments for argv-style terminal launches."
  @spec terminal_shim_argv_env(keyword()) :: [String.t()]
  def terminal_shim_argv_env(opts \\ []) do
    Shims.argv_env(opts)
  end

  @doc "Shell command for panes that should enter DevIDE's shell integration."
  @spec terminal_shell_command() :: String.t()
  def terminal_shell_command do
    Shims.shell_command()
  end

  @doc "Pushes per-viewer terminal scheme variables into a tmux session environment."
  @spec push_terminal_theme_session_env(String.t(), Theme.scheme(), String.t() | nil) ::
          :ok | {:error, term()}
  def push_terminal_theme_session_env(session, scheme, preset \\ nil)
      when is_binary(session) and scheme in [:dark, :light] do
    result = tmux_adapter().set_environments(session, Shims.theme_env(scheme, preset))
    # Never raises: ToolThemes rescues and logs per-tool failures internally.
    _ = ToolThemes.ensure_all(scheme)
    result
  end

  @doc "Subscribes to tmux session cleanup notifications for a session."
  @spec subscribe_tmux_session_cleanup(String.t()) :: :ok | {:error, term()}
  def subscribe_tmux_session_cleanup(session) do
    TmuxJanitor.subscribe(session)
  end

  @doc "Unsubscribes from tmux session cleanup notifications for a session."
  @spec unsubscribe_tmux_session_cleanup(String.t()) :: :ok
  def unsubscribe_tmux_session_cleanup(session) do
    TmuxJanitor.unsubscribe(session)
  end

  @doc "True when a tmux session belongs to the workspace namespace."
  @spec tmux_session_in_workspace?(String.t(), String.t() | map()) :: boolean()
  def tmux_session_in_workspace?(session, workspace) do
    TmuxScope.session_in_workspace?(session, workspace)
  end

  @doc "Canonical tmux session prefix for a workspace identifier or name."
  @spec tmux_workspace_session_prefix(String.t()) :: String.t()
  def tmux_workspace_session_prefix(workspace_id_or_name) do
    Tmux.workspace_session_prefix(workspace_id_or_name)
  end

  @doc "Canonical tmux session name for a workspace shell id."
  @spec tmux_session_name(String.t(), String.t()) :: String.t()
  def tmux_session_name(workspace_name, sid) do
    Tmux.session_name(workspace_name, sid)
  end

  @doc "Snapshot tmux topology through the configured adapter unless one is supplied."
  @spec tmux_topology_snapshot(String.t(), keyword()) :: map()
  def tmux_topology_snapshot(session, opts \\ []) do
    TmuxTopology.snapshot(session, Keyword.put_new(opts, :tmux, tmux_adapter()))
  end

  @doc "Refreshes a tmux topology session immediately through the shared watcher."
  @spec tmux_topology_refresh_now(String.t(), keyword()) :: map()
  def tmux_topology_refresh_now(session, opts \\ []) do
    TmuxTopology.refresh_now(session, opts)
  end

  @doc "Switches the caller's tmux topology subscription to another session."
  @spec switch_tmux_topology_subscription(String.t() | nil, String.t(), keyword()) ::
          {:ok, map()}
  def switch_tmux_topology_subscription(old_session, new_session, opts \\ []) do
    TmuxTopology.switch_subscription(old_session, new_session, opts)
  end

  @doc "Module tag used by tmux topology PubSub broadcasts."
  @spec tmux_topology_event_source() :: module()
  def tmux_topology_event_source, do: TmuxTopology

  @doc "True when a PubSub source is the tmux topology broadcaster."
  @spec tmux_topology_event_source?(module()) :: boolean()
  def tmux_topology_event_source?(source), do: source == TmuxTopology

  @doc "Selects a tmux pane through the configured adapter."
  @spec select_tmux_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def select_tmux_pane(session, pane_id) do
    tmux_adapter().select_pane(session, pane_id)
  end

  @doc "Splits a tmux pane through the configured adapter."
  @spec split_tmux_pane(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def split_tmux_pane(session, pane_id, direction, opts \\ []) do
    tmux_adapter().split_pane(session, pane_id, direction, opts)
  end

  @doc "Resizes a tmux pane through the configured adapter."
  @spec resize_tmux_pane(String.t(), String.t(), String.t(), pos_integer()) ::
          :ok | {:error, term()}
  def resize_tmux_pane(session, pane_id, direction, amount) do
    tmux_adapter().resize_pane(session, pane_id, direction, amount)
  end

  @doc "Kills a tmux pane through the configured adapter."
  @spec kill_tmux_pane(String.t(), String.t()) :: :ok | {:error, term()}
  def kill_tmux_pane(session, pane_id) do
    tmux_adapter().kill_pane(session, pane_id)
  end

  @doc "Default pane resize amount."
  @spec tmux_resize_amount_default() :: pos_integer()
  def tmux_resize_amount_default do
    Tmux.resize_amount_default()
  end

  @doc "Maximum allowed pane resize amount."
  @spec tmux_resize_amount_max() :: pos_integer()
  def tmux_resize_amount_max do
    Tmux.resize_amount_max()
  end

  @doc "Configure tracked metadata for a tmux topology session."
  @spec configure_tmux_topology(String.t(), keyword()) :: term()
  def configure_tmux_topology(session, opts) do
    TmuxTopology.configure(session, opts)
  end

  @doc "Refresh a tmux topology session."
  @spec refresh_tmux_topology(String.t()) :: term()
  def refresh_tmux_topology(session) do
    TmuxTopology.refresh(session)
  end
end
