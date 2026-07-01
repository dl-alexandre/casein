defmodule DevIDE.Terminals.Tmux do
  @moduledoc """
  DevIDE facade over `TmuxCtl.Client` for workspace tmux sessions.

  Session naming lives in `DevIDE.Terminals.TmuxPolicy`. Subprocess argv
  wrapping (host vs container tmux) is configured via `config :dev_ide, :tmux_ctl`.
  See `docs/tmux_control_plane.md`.
  """

  @behaviour TmuxCtl.Adapter

  alias DevIDE.Terminals.TmuxPolicy
  alias DevIDE.Terminals.TmuxRunner

  defdelegate host_shell?(), to: TmuxRunner
  defdelegate container_has_tmux?(cwd), to: TmuxRunner

  defdelegate ensure_session(session, cwd), to: TmuxCtl.Client
  defdelegate attach(session), to: TmuxCtl.Client
  defdelegate inject(target, text), to: TmuxCtl.Client
  defdelegate inject(target, text, opts), to: TmuxCtl.Client
  defdelegate capture_recent(target), to: TmuxCtl.Client
  defdelegate capture_recent(target, lines), to: TmuxCtl.Client
  defdelegate capture_recent(target, lines, opts), to: TmuxCtl.Client
  defdelegate send_keys(session, keys), to: TmuxCtl.Client
  defdelegate send_keys(session, keys, opts), to: TmuxCtl.Client
  defdelegate list_session_windows(session), to: TmuxCtl.Client
  defdelegate list_session_panes(session), to: TmuxCtl.Client
  defdelegate session_topology(session), to: TmuxCtl.Client
  defdelegate directory_inventory(), to: TmuxCtl.Client
  defdelegate new_window(session), to: TmuxCtl.Client
  defdelegate new_window(session, opts), to: TmuxCtl.Client
  defdelegate select_window(session, window_id), to: TmuxCtl.Client
  defdelegate cycle_window(session, dir), to: TmuxCtl.Client
  defdelegate consolidate_sessions(session, source_sessions), to: TmuxCtl.Client
  defdelegate select_pane(session, pane_id), to: TmuxCtl.Client
  defdelegate navigate_pane(session, dir), to: TmuxCtl.Client
  defdelegate zoom_pane(session, pane_id), to: TmuxCtl.Client
  defdelegate ensure_zoomed(session, pane_id, desired?), to: TmuxCtl.Client
  defdelegate kill_other_panes(session, pane_id), to: TmuxCtl.Client
  defdelegate select_layout(session, layout), to: TmuxCtl.Client
  defdelegate next_layout(session), to: TmuxCtl.Client
  defdelegate kill_pane(session, pane_id), to: TmuxCtl.Client
  defdelegate split_pane(session, pane_id, direction), to: TmuxCtl.Client
  defdelegate split_pane(session, pane_id, direction, opts), to: TmuxCtl.Client
  defdelegate resize_pane(session, pane_id, direction), to: TmuxCtl.Client
  defdelegate resize_pane(session, pane_id, direction, amount), to: TmuxCtl.Client
  defdelegate resize_amount_default(), to: TmuxCtl.Client
  defdelegate resize_amount_max(), to: TmuxCtl.Client
  defdelegate rename_window(session, window_id, name), to: TmuxCtl.Client
  defdelegate set_session_alias(session, name), to: TmuxCtl.Client
  defdelegate set_pane_role(session, pane_id, role), to: TmuxCtl.Client
  defdelegate list_windows(), to: TmuxCtl.Client
  defdelegate list_sessions(), to: TmuxCtl.Client
  defdelegate list_panes(), to: TmuxCtl.Client
  defdelegate kill_window(session, window_id), to: TmuxCtl.Client
  defdelegate kill(session), to: TmuxCtl.Client
  defdelegate session_exists?(session), to: TmuxCtl.Client
  defdelegate session_alive?(session), to: TmuxCtl.Client
  defdelegate apply_defaults(session), to: TmuxCtl.Client
  defdelegate set_environment(session, key, value), to: TmuxCtl.Client
  defdelegate set_environments(session, env), to: TmuxCtl.Client
  defdelegate send_command(session, cmd), to: TmuxCtl.Client
  defdelegate send_command(session, cmd, opts), to: TmuxCtl.Client
  defdelegate paste_text(session, text), to: TmuxCtl.Client
  defdelegate paste_text(session, text, opts), to: TmuxCtl.Client
  defdelegate resize_window(session, cols, rows), to: TmuxCtl.Client
  defdelegate window_size(session), to: TmuxCtl.Client
  defdelegate capture_scrollback(session), to: TmuxCtl.Client
  defdelegate capture_scrollback(session, opts), to: TmuxCtl.Client
  defdelegate tail_lines(output, n), to: TmuxCtl.Client

  defdelegate session_name(workspace_name, sid), to: TmuxPolicy
  defdelegate workspace_session_prefix(workspace_name), to: TmuxPolicy
end
