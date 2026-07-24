defmodule DevIDE.Terminals do
  @moduledoc """
  Public API for terminal sessions.

  Ownership goal:
  - This module (and submodules under DevIDE.Terminals) will become the single
    place for session identity, creation, attachment, and state.
  - The web layer (LiveViews and Channels) will only call into this API.
  """

  alias DevIDE.Terminals.{
    AgentPrompt,
    Clipboard,
    Directory,
    ModeBoundary,
    Owner,
    SessionTemplates,
    Themes,
    TmuxOps,
    WorkflowOps
  }

  @type session_loc :: DevIDE.Terminals.Session.loc()

  defdelegate new_shell(workspace_id, sid, opts \\ []), to: Directory
  defdelegate new_agent(agent_id, opts \\ []), to: Directory
  defdelegate list_attachable(workspace_id), to: Directory
  defdelegate session_tabs(workspace_id, opts \\ []), to: Directory
  defdelegate subscribe_session_tabs(workspace_id, opts \\ []), to: Directory
  defdelegate unsubscribe_session_tabs(workspace_id, watcher_pid \\ self()), to: Directory
  defdelegate visible_tabs(tabs, default_sid), to: Directory
  defdelegate shell_family(sid), to: Directory
  defdelegate with_default_shell(tabs, default_sid, workspace_id, workspace_name), to: Directory
  defdelegate resolve(sid), to: Directory
  defdelegate shell_session?(info), to: Directory
  defdelegate session_info?(term), to: Directory
  defdelegate prepare_attachment(sid), to: Directory
  defdelegate fetch_session_tab(workspace_id, sid, opts \\ []), to: Directory
  defdelegate read_session_tabs(workspace_id, opts \\ []), to: Directory
  defdelegate refresh_session_tabs_now(workspace_id, opts \\ []), to: Directory
  defdelegate session_tabs_event_source(), to: Directory
  defdelegate session_tabs_event_source?(source), to: Directory

  defdelegate attachment_policy(info, requested), to: ModeBoundary
  defdelegate raw_terminal_allowed?(workspace_id, host_id), to: ModeBoundary
  defdelegate authorize_raw_terminal(workspace_id, opts), to: ModeBoundary
  defdelegate terminal_boundary_reason(reason), to: ModeBoundary
  defdelegate raw_terminal_mode_allowed?(workspace_mode, host_id), to: ModeBoundary
  defdelegate raw_terminal_default?(workspace_mode, host_id), to: ModeBoundary
  defdelegate initial_terminal_mode(workspace_mode, host_id), to: ModeBoundary
  defdelegate session_switch_terminal_mode(info, workspace_mode, host_id), to: ModeBoundary
  defdelegate tmux_mutations_enabled?(kind), to: ModeBoundary

  defdelegate attach(info, opts), to: Owner
  defdelegate owner_attach(workspace_id, info, opts), to: Owner
  defdelegate owner_detach(owner_pid, subscriber), to: Owner
  defdelegate owner_input(owner_pid, data), to: Owner
  defdelegate owner_query_response(owner_pid, data), to: Owner
  defdelegate owner_set_theme(owner_pid, scheme, preset), to: Owner
  defdelegate owner_resize(owner_pid, cols, rows), to: Owner
  defdelegate owner_set_active(owner_pid, active?), to: Owner
  defdelegate owner_subscriber_count(owner_pid), to: Owner
  defdelegate raw_shell_attach(workspace_id, sid, loc), to: Owner
  defdelegate session_backend_module(), to: Owner
  defdelegate send_session_input(session_pid, data), to: Owner
  defdelegate capture_ghostty_snapshot(term, workspace_id), to: Owner

  defdelegate valid_terminal_theme_preset?(preset_id), to: Themes
  defdelegate terminal_theme_client_bundle(preset_id \\ nil), to: Themes
  defdelegate terminal_theme_bundle(preset_id \\ nil), to: Themes
  defdelegate active_terminal_theme(theme_bundle, scheme), to: Themes
  defdelegate rewrite_terminal_pty_write(data, theme), to: Themes
  defdelegate terminal_sync_output_active_after?(binary, current?), to: Themes

  defdelegate save_clipboard_image(root, params), to: Clipboard
  defdelegate save_clipboard_file(root, params), to: Clipboard
  defdelegate clipboard_max_file_bytes(), to: Clipboard

  defdelegate periodic_measurements(), to: AgentPrompt
  defdelegate agent_window_quiet?(window), to: AgentPrompt
  defdelegate send_agent_prompt(session, pane, text, opts \\ []), to: AgentPrompt
  defdelegate find_agent_pane(session, opts \\ []), to: AgentPrompt
  defdelegate send_agent_prompt_to_agent_pane(session, text, opts \\ []), to: AgentPrompt

  defdelegate backend(), to: TmuxOps
  defdelegate tmux_adapter(), to: TmuxOps
  defdelegate tmux_version(), to: TmuxOps
  defdelegate tmux_host_shell?(), to: TmuxOps
  defdelegate tmux_local_argv_wrapped?(), to: TmuxOps
  defdelegate tmux_container_has_tmux?(cwd), to: TmuxOps
  defdelegate tmux_server_args(), to: TmuxOps
  defdelegate tmux_host_argv(args), to: TmuxOps
  defdelegate clean_terminal_argv(argv), to: TmuxOps
  defdelegate terminal_shim_tmux_env_flags(opts \\ []), to: TmuxOps
  defdelegate terminal_shim_argv_env(opts \\ []), to: TmuxOps
  defdelegate terminal_shell_command(), to: TmuxOps
  defdelegate push_terminal_theme_session_env(session, scheme, preset \\ nil), to: TmuxOps
  defdelegate subscribe_tmux_session_cleanup(session), to: TmuxOps
  defdelegate unsubscribe_tmux_session_cleanup(session), to: TmuxOps
  defdelegate tmux_session_in_workspace?(session, workspace), to: TmuxOps
  defdelegate tmux_workspace_session_prefix(workspace_id_or_name), to: TmuxOps
  defdelegate tmux_session_name(workspace_name, sid), to: TmuxOps
  defdelegate tmux_topology_snapshot(session, opts \\ []), to: TmuxOps
  defdelegate tmux_topology_refresh_now(session, opts \\ []), to: TmuxOps
  defdelegate switch_tmux_topology_subscription(old_session, new_session, opts \\ []), to: TmuxOps
  defdelegate tmux_topology_event_source(), to: TmuxOps
  defdelegate tmux_topology_event_source?(source), to: TmuxOps
  defdelegate select_tmux_pane(session, pane_id), to: TmuxOps
  defdelegate split_tmux_pane(session, pane_id, direction, opts \\ []), to: TmuxOps
  defdelegate resize_tmux_pane(session, pane_id, direction, amount), to: TmuxOps
  defdelegate kill_tmux_pane(session, pane_id), to: TmuxOps
  defdelegate tmux_resize_amount_default(), to: TmuxOps
  defdelegate tmux_resize_amount_max(), to: TmuxOps
  defdelegate configure_tmux_topology(session, opts), to: TmuxOps
  defdelegate refresh_tmux_topology(session), to: TmuxOps

  defdelegate session_templates(workspace_id \\ nil), to: SessionTemplates
  defdelegate get_session_template(id), to: SessionTemplates
  defdelegate export_session_template(topology, opts \\ []), to: SessionTemplates
  defdelegate session_template_to_yaml(template), to: SessionTemplates
  defdelegate dry_run_session_template(template_or_id, opts \\ []), to: SessionTemplates
  defdelegate execute_session_template(session, template_or_id, opts \\ []), to: SessionTemplates
  defdelegate list_saved_templates(workspace_id, opts \\ []), to: SessionTemplates
  defdelegate get_saved_template(workspace_id, id), to: SessionTemplates
  defdelegate save_template(attrs), to: SessionTemplates
  defdelegate update_saved_template(workspace_id, id, attrs, opts \\ []), to: SessionTemplates

  defdelegate duplicate_saved_template(workspace_id, id, attrs \\ %{}, opts \\ []),
    to: SessionTemplates

  defdelegate delete_saved_template(workspace_id, id), to: SessionTemplates
  defdelegate saved_template_apply_supported?(saved), to: SessionTemplates
  defdelegate dry_run_saved_template(workspace_id, id, opts \\ []), to: SessionTemplates
  defdelegate execute_saved_template(workspace_id, session, id, opts \\ []), to: SessionTemplates
  defdelegate diff_saved_template(workspace_id, id, topology, opts \\ []), to: SessionTemplates

  defdelegate execute_saved_template_reconcile(workspace_id, session, id, topology, opts \\ []),
    to: SessionTemplates

  defdelegate workflow_specs(workspace_id), to: WorkflowOps
  defdelegate workflow_palette_runnable?(spec), to: WorkflowOps
  defdelegate workflow_command_id(spec), to: WorkflowOps
end
