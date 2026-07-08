defmodule DevIDE.Terminals do
  @moduledoc """
  Public API for terminal sessions.

  Ownership goal:
  - This module (and submodules under DevIDE.Terminals) will become the single
    place for session identity, creation, attachment, and state.
  - The web layer (LiveViews and Channels) will only call into this API.
  """
  require Logger

  alias DevIDE.Terminals.{
    Attachment,
    Activity,
    AgentPane,
    AgentPromptSender,
    CleanExec,
    ClipboardPaste,
    GhosttyRawAdapter,
    GhosttySnapshot,
    ModePolicy,
    Session,
    SessionTemplate,
    SessionDirectory,
    SessionOwner,
    SessionRegistry,
    Shims,
    SyncOutput,
    Templates,
    Theme,
    Tmux,
    TmuxJanitor,
    TmuxRunner,
    TmuxScope,
    TmuxServer,
    TmuxTopology,
    ToolThemes,
    Telemetry,
    Workflows
  }

  alias DevIDE.Terminals.Session.Info
  alias DevIDE.Terminals.SessionTemplate.Export, as: SessionTemplateExport
  alias DevIDE.Terminals.SessionDirectory.Compose

  @type session_loc :: Session.loc()

  defdelegate new_shell(workspace_id, sid, opts \\ []), to: Info
  defdelegate new_agent(agent_id, opts \\ []), to: Info

  @doc "Lists all attachable terminal sessions for a workspace."
  @spec list_attachable(String.t()) :: [Info.t()]
  def list_attachable(workspace_id) do
    SessionRegistry.list_attachable(workspace_id)
  end

  @doc """
  Canonical session tab list for a workspace (live shells + scanned tmux
  sessions, deduplicated). Served by the per-workspace `SessionDirectory`;
  viewer-independent — apply `visible_tabs/2`.
  """
  @spec session_tabs(String.t(), keyword()) :: [Info.t()]
  defdelegate session_tabs(workspace_id, opts \\ []), to: SessionDirectory, as: :tabs

  @doc "Subscribes the caller to `{:sessions_updated, workspace_id, tabs}` broadcasts."
  @spec subscribe_session_tabs(String.t(), keyword()) :: :ok | {:error, term()}
  defdelegate subscribe_session_tabs(workspace_id, opts \\ []),
    to: SessionDirectory,
    as: :subscribe

  @doc "Drops the caller's session-tab PubSub subscription and directory watch."
  @spec unsubscribe_session_tabs(String.t(), pid()) :: :ok
  defdelegate unsubscribe_session_tabs(workspace_id, watcher_pid \\ self()),
    to: SessionDirectory,
    as: :unsubscribe

  @doc "Applies the per-viewer staleness/default-shell filters to a tab list."
  @spec visible_tabs([Info.t()], String.t() | nil) :: [Info.t()]
  defdelegate visible_tabs(tabs, default_sid), to: Compose, as: :visible_for

  @doc "Returns the workspace shell family prefix for a terminal session id."
  @spec shell_family(String.t() | nil) :: String.t() | nil
  defdelegate shell_family(sid), to: Compose

  @doc "Ensures the viewer's landing session is present so the picker always shows a home row."
  @spec with_default_shell([Info.t()], String.t() | nil, String.t(), String.t()) :: [Info.t()]
  defdelegate with_default_shell(tabs, default_sid, workspace_id, workspace_name), to: Compose

  @doc "Resolves a session identifier into session information."
  @spec resolve(String.t()) :: {:ok, Info.t()} | :error
  def resolve(sid) do
    SessionRegistry.resolve(sid)
  end

  @doc "True when the resolved session info is for an interactive shell."
  @spec shell_session?(Info.t() | term()) :: boolean()
  def shell_session?(%Info{kind: :shell}), do: true
  def shell_session?(_), do: false

  @doc "True when the term is a terminal session info struct."
  @spec session_info?(term()) :: boolean()
  def session_info?(%Info{}), do: true
  def session_info?(_), do: false

  @doc "Prepares attachment data for a given session id."
  @spec prepare_attachment(String.t()) :: {:ok, Info.t()} | :error
  def prepare_attachment(sid) do
    resolve(sid)
  end

  @doc """
  Determines the effective attachment mode for a session. Always `:raw`.
  """
  @spec attachment_policy(Info.t(), :raw) :: {:ok, :raw}
  defdelegate attachment_policy(info, requested), to: ModePolicy, as: :attachment_mode

  @doc "Opens a unified attachment handle for the given session."
  @spec attach(Info.t(), keyword()) :: {:ok, Attachment.t()} | {:error, term()}
  defdelegate attach(info, opts), to: Attachment, as: :open

  @doc "Attaches a terminal owner for one logical session and subscribes the caller."
  @spec owner_attach(String.t(), Info.t(), keyword()) :: {:ok, pid(), map()} | {:error, term()}
  def owner_attach(workspace_id, %Info{} = info, opts) when is_binary(workspace_id) do
    SessionOwner.attach(workspace_id, info, opts)
  end

  @doc "Detaches a caller from a terminal owner."
  @spec owner_detach(pid(), pid()) :: :ok | {:error, term()}
  def owner_detach(owner_pid, subscriber) when is_pid(owner_pid) and is_pid(subscriber) do
    if Process.alive?(owner_pid) do
      try do
        SessionOwner.detach(owner_pid, subscriber)
      rescue
        e in [ArgumentError] -> {:error, e}
      catch
        :exit, {:noproc, _} ->
          Logger.warning("terminal owner orphaned detach (no-op on dead owner)", owner: owner_pid)
          :telemetry.execute([:dev_ide, :terminals, :owner, :orphaned_detach], %{count: 1}, %{})
          :ok
      end
    else
      Logger.debug("terminal owner detach on dead pid (orphaned)", owner: owner_pid)
      :telemetry.execute([:dev_ide, :terminals, :owner, :orphaned_detach], %{count: 1}, %{})
      :ok
    end
  end

  @doc "Sends raw terminal input through the terminal owner."
  @spec owner_input(pid(), binary()) :: :ok
  def owner_input(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    SessionOwner.input(owner_pid, data)
  end

  @doc """
  Forwards a viewer-generated terminal query response through the owner's
  single-responder gate (raw bytes; the owner rewrites with the session theme).
  """
  @spec owner_query_response(pid(), binary()) :: :ok
  def owner_query_response(owner_pid, data) when is_pid(owner_pid) and is_binary(data) do
    SessionOwner.query_response(owner_pid, data)
  end

  @doc "Sets the session-level terminal theme on the owner (last writer wins)."
  @spec owner_set_theme(pid(), Theme.scheme(), String.t()) :: :ok
  def owner_set_theme(owner_pid, scheme, preset)
      when is_pid(owner_pid) and scheme in [:dark, :light] and is_binary(preset) do
    SessionOwner.set_theme(owner_pid, scheme, preset)
  end

  @doc "Resizes terminal viewport through the terminal owner."
  @spec owner_resize(pid(), integer(), integer()) :: :ok
  def owner_resize(owner_pid, cols, rows) when is_integer(cols) and is_integer(rows) do
    SessionOwner.resize(owner_pid, cols, rows)
  end

  @doc """
  Reports whether the calling viewer is the active (visible + focused)
  attachment, so the owner can size the shared PTY to the focused viewer.
  """
  @spec owner_set_active(pid(), boolean()) :: :ok
  def owner_set_active(owner_pid, active?) when is_pid(owner_pid) and is_boolean(active?) do
    SessionOwner.set_active(owner_pid, active?)
  end

  @doc """
  Cheap subscriber count (map_size of subscribers) for the given owner pid.
  Enables UX (e.g. "3 viewers" badge) and dashboard queries for channel-raw
  owners. See SessionOwner.subscriber_count/1.
  """
  @spec owner_subscriber_count(pid()) :: non_neg_integer()
  def owner_subscriber_count(owner_pid) when is_pid(owner_pid) do
    SessionOwner.subscriber_count(owner_pid)
  end

  @doc "Terminal-specific telemetry poller measurements."
  @spec periodic_measurements() :: list()
  def periodic_measurements do
    Telemetry.periodic_measurements()
  end

  @doc "True when a tmux window's agent process has been quiet long enough to need attention."
  @spec agent_window_quiet?(map()) :: boolean()
  def agent_window_quiet?(window) do
    Activity.agent_window_quiet?(window)
  end

  @doc """
  Raw shell attachment bridge (via GhosttyRawAdapter).

  Canonical entry for owner-driven raw joins that must coexist with
  PaneWorker/Ghostty-managed tmux sessions (short-term migration path).
  """
  @spec raw_shell_attach(String.t(), String.t(), term()) :: {:ok, pid()} | {:error, term()}
  def raw_shell_attach(workspace_id, sid, loc) do
    GhosttyRawAdapter.ensure_raw_shell(workspace_id, sid, loc)
  end

  @doc "Default legacy terminal session backend module."
  @spec session_backend_module() :: module()
  def session_backend_module, do: Session

  @doc "Sends input through the legacy shared terminal session backend."
  @spec send_session_input(pid(), binary()) :: :ok
  def send_session_input(session_pid, data) when is_pid(session_pid) and is_binary(data) do
    Session.send_input(session_pid, data)
  end

  @doc "True when raw terminal access is allowed for the workspace/host pair."
  @spec raw_terminal_allowed?(String.t(), String.t() | nil) :: boolean()
  def raw_terminal_allowed?(workspace_id, host_id) do
    DevIDE.Terminals.Boundary.raw_allowed?(workspace_id, host_id)
  end

  @doc "Authorizes raw terminal access through the terminal boundary policy."
  @spec authorize_raw_terminal(String.t(), keyword()) :: :ok | {:error, term()}
  def authorize_raw_terminal(workspace_id, opts) do
    DevIDE.Terminals.Boundary.authorize_raw(workspace_id, opts)
  end

  @doc "Formats a terminal boundary reason for clients."
  @spec terminal_boundary_reason(term()) :: String.t()
  def terminal_boundary_reason(reason) do
    DevIDE.Terminals.Boundary.format_reason(reason)
  end

  @doc "True when raw terminal mode is reachable for a workspace mode/host pair."
  @spec raw_terminal_mode_allowed?(atom() | nil, String.t() | nil) :: boolean()
  def raw_terminal_mode_allowed?(workspace_mode, host_id) do
    ModePolicy.raw_terminal_allowed?(workspace_mode, host_id)
  end

  @doc "True when the initial terminal should default to raw mode."
  @spec raw_terminal_default?(atom() | nil, String.t() | nil) :: boolean()
  def raw_terminal_default?(workspace_mode, host_id) do
    ModePolicy.raw_default?(workspace_mode, host_id)
  end

  @doc "Initial terminal mode for a workspace mode/host pair."
  @spec initial_terminal_mode(atom() | nil, String.t() | nil) :: ModePolicy.mode()
  def initial_terminal_mode(workspace_mode, host_id) do
    ModePolicy.initial_mode(workspace_mode, host_id)
  end

  @doc "Terminal mode to use when switching to a session."
  @spec session_switch_terminal_mode(term(), atom() | nil, String.t() | nil) :: atom()
  def session_switch_terminal_mode(info, workspace_mode, host_id) do
    ModePolicy.session_switch_mode(info, workspace_mode, host_id)
  end

  @doc "True when tmux layout mutations are allowed for a session kind."
  @spec tmux_mutations_enabled?(atom() | term()) :: boolean()
  defdelegate tmux_mutations_enabled?(kind), to: ModePolicy

  @doc "True when a terminal theme preset id is selectable."
  @spec valid_terminal_theme_preset?(String.t()) :: boolean()
  def valid_terminal_theme_preset?(preset_id) do
    Theme.valid_preset?(preset_id)
  end

  @doc "JSON-safe terminal theme bundle for LiveView and browser clients."
  @spec terminal_theme_client_bundle(String.t() | nil) :: map()
  def terminal_theme_client_bundle(preset_id \\ nil) do
    Theme.client_bundle(preset_id)
  end

  @doc "Loads the renderer terminal theme bundle for a preset id."
  @spec terminal_theme_bundle(String.t() | nil) :: map()
  def terminal_theme_bundle(preset_id \\ nil) do
    Theme.load_bundle(preset_id)
  end

  @doc "Selects the active terminal theme for a color scheme."
  @spec active_terminal_theme(map(), Theme.scheme()) :: term()
  def active_terminal_theme(theme_bundle, scheme) do
    Theme.active(theme_bundle, scheme)
  end

  @doc "Rewrites terminal PTY color query responses for the active theme."
  @spec rewrite_terminal_pty_write(binary(), term()) :: binary()
  def rewrite_terminal_pty_write(data, theme) do
    Theme.rewrite_pty_write(data, theme)
  end

  @doc "Tracks DEC 2026 synchronized-output state after a PTY chunk."
  @spec terminal_sync_output_active_after?(binary(), boolean()) :: boolean()
  def terminal_sync_output_active_after?(binary, current?) do
    SyncOutput.active_after?(binary, current?)
  end

  @doc "Captures a Ghostty terminal snapshot artifact set."
  @spec capture_ghostty_snapshot(pid(), String.t()) :: map()
  def capture_ghostty_snapshot(term, workspace_id) do
    GhosttySnapshot.capture(term, workspace_id)
  end

  @doc "Saves a clipboard image payload under a workspace root."
  @spec save_clipboard_image(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def save_clipboard_image(root, params) do
    ClipboardPaste.save_image(root, params)
  end

  @doc "Saves a clipboard file payload under a workspace root."
  @spec save_clipboard_file(String.t(), map()) :: {:ok, map()} | {:error, atom()}
  def save_clipboard_file(root, params) do
    ClipboardPaste.save_file(root, params)
  end

  @doc "Maximum allowed clipboard paste file size in bytes."
  @spec clipboard_max_file_bytes() :: pos_integer()
  def clipboard_max_file_bytes do
    ClipboardPaste.max_file_bytes()
  end

  @doc "Sends an agent prompt to a tmux pane in small, line-preserving chunks."
  @spec send_agent_prompt(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AgentPromptSender.result()} | {:error, map()}
  defdelegate send_agent_prompt(session, pane, text, opts \\ []),
    to: AgentPromptSender,
    as: :send_prompt

  @doc "Finds the role-marked agent pane for a tmux session."
  @spec find_agent_pane(String.t(), keyword()) :: {:ok, map()} | {:error, map()}
  defdelegate find_agent_pane(session, opts \\ []), to: AgentPane, as: :find

  @doc "Sends an agent prompt to the role-marked agent pane."
  @spec send_agent_prompt_to_agent_pane(String.t(), String.t(), keyword()) ::
          {:ok, AgentPromptSender.result()} | {:error, map()}
  defdelegate send_agent_prompt_to_agent_pane(session, text, opts \\ []),
    to: AgentPromptSender,
    as: :send_to_agent_pane

  @doc "Configured tmux adapter."
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

  @doc "Fetches one canonical session tab for a workspace."
  @spec fetch_session_tab(String.t(), String.t(), keyword()) :: {:ok, Info.t()} | :error
  def fetch_session_tab(workspace_id, sid, opts \\ []) do
    SessionDirectory.fetch(workspace_id, sid, opts)
  end

  @doc "Reads cached canonical session tabs for a workspace."
  @spec read_session_tabs(String.t(), keyword()) :: [Info.t()]
  def read_session_tabs(workspace_id, opts \\ []) do
    SessionDirectory.read(workspace_id, opts)
  end

  @doc "Forces a canonical session tab refresh for a workspace."
  @spec refresh_session_tabs_now(String.t(), keyword()) :: [Info.t()]
  def refresh_session_tabs_now(workspace_id, opts \\ []) do
    SessionDirectory.refresh_now(workspace_id, opts)
  end

  @doc "Module tag used by session directory PubSub broadcasts."
  @spec session_tabs_event_source() :: module()
  def session_tabs_event_source, do: SessionDirectory

  @doc "True when a PubSub source is the session tabs broadcaster."
  @spec session_tabs_event_source?(module()) :: boolean()
  def session_tabs_event_source?(source), do: source == SessionDirectory

  @doc "Lists built-in and, when workspace_id is supplied, saved session template stubs."
  @spec session_templates(String.t() | nil) :: [SessionTemplate.t()]
  def session_templates(workspace_id \\ nil) do
    SessionTemplate.list(workspace_id)
  end

  @doc "Fetches a built-in session template by id."
  @spec get_session_template(String.t()) ::
          {:ok, SessionTemplate.t()} | {:error, :template_not_found}
  def get_session_template(id) do
    SessionTemplate.get(id)
  end

  @doc "Builds a template export from a tmux topology snapshot."
  @spec export_session_template(map(), keyword()) :: {:ok, map()} | {:error, atom()}
  def export_session_template(topology, opts \\ []) do
    SessionTemplate.export_topology(topology, opts)
  end

  @doc "Serializes a session template export to YAML."
  @spec session_template_to_yaml(map()) :: String.t()
  def session_template_to_yaml(template) do
    SessionTemplateExport.to_yaml(template)
  end

  @doc "Runs a dry-run plan for a built-in session template."
  @spec dry_run_session_template(String.t() | SessionTemplate.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def dry_run_session_template(template_or_id, opts \\ []) do
    SessionTemplate.dry_run(template_or_id, opts)
  end

  @doc "Executes a built-in session template."
  @spec execute_session_template(String.t(), String.t() | SessionTemplate.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_session_template(session, template_or_id, opts \\ []) do
    SessionTemplate.execute(session, template_or_id, opts)
  end

  @doc "Lists saved session templates for a workspace."
  @spec list_saved_templates(String.t(), keyword()) :: [Templates.saved()]
  def list_saved_templates(workspace_id, opts \\ []) do
    Templates.list_for_workspace(workspace_id, opts)
  end

  @doc "Fetches a saved session template scoped to a workspace."
  @spec get_saved_template(String.t(), String.t()) ::
          {:ok, Templates.saved()} | {:error, :not_found}
  def get_saved_template(workspace_id, id) do
    Templates.get(workspace_id, id)
  end

  @doc "Saves a session template export."
  @spec save_template(map()) :: {:ok, Templates.saved()} | {:error, Ecto.Changeset.t()}
  def save_template(attrs) do
    Templates.save(attrs)
  end

  @doc "Updates a saved session template."
  @spec update_saved_template(String.t(), String.t(), map(), keyword()) ::
          {:ok, Templates.saved()}
          | {:error, :not_found | :name_required | :name_taken | :invalid_tags}
  def update_saved_template(workspace_id, id, attrs, opts \\ []) do
    Templates.update(workspace_id, id, attrs, opts)
  end

  @doc "Duplicates a saved session template."
  @spec duplicate_saved_template(String.t(), String.t(), map(), keyword()) ::
          {:ok, Templates.saved()}
          | {:error, :not_found | :name_required | :name_taken | :invalid_tags}
  def duplicate_saved_template(workspace_id, id, attrs \\ %{}, opts \\ []) do
    Templates.duplicate(workspace_id, id, attrs, opts)
  end

  @doc "Deletes a saved session template."
  @spec delete_saved_template(String.t(), String.t()) :: :ok | {:error, :not_found}
  def delete_saved_template(workspace_id, id) do
    Templates.delete(workspace_id, id)
  end

  @doc "True when a saved session template can be applied."
  @spec saved_template_apply_supported?(Templates.saved()) :: boolean()
  def saved_template_apply_supported?(saved) do
    Templates.apply_supported?(saved)
  end

  @doc "Dry-runs a saved session template."
  @spec dry_run_saved_template(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def dry_run_saved_template(workspace_id, id, opts \\ []) do
    Templates.dry_run(workspace_id, id, opts)
  end

  @doc "Executes a saved session template."
  @spec execute_saved_template(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_saved_template(workspace_id, session, id, opts \\ []) do
    Templates.execute(workspace_id, session, id, opts)
  end

  @doc "Diffs a saved template against the current tmux topology."
  @spec diff_saved_template(String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def diff_saved_template(workspace_id, id, topology, opts \\ []) do
    Templates.diff(workspace_id, id, topology, opts)
  end

  @doc "Executes a saved template reconciliation plan."
  @spec execute_saved_template_reconcile(String.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def execute_saved_template_reconcile(workspace_id, session, id, topology, opts \\ []) do
    Templates.execute_reconcile(workspace_id, session, id, topology, opts)
  end

  @doc "Lists terminal workflow specs for a workspace."
  @spec workflow_specs(String.t()) :: [Workflows.spec()]
  def workflow_specs(workspace_id) do
    Workflows.list_specs(workspace_id)
  end

  @doc "True when a workflow spec can run from the palette without extra arguments."
  @spec workflow_palette_runnable?(Workflows.spec()) :: boolean()
  def workflow_palette_runnable?(spec) do
    Workflows.palette_runnable?(spec)
  end

  @doc "Encoded terminal workflow command id using default placeholder bindings."
  @spec workflow_command_id(Workflows.spec()) :: String.t()
  def workflow_command_id(spec) do
    Workflows.command_id(spec)
  end
end
