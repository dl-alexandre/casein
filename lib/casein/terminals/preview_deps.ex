defmodule Casein.Terminals.PreviewDeps do
  @moduledoc """
  Core-side impl of `Casein.Previews.Deps.Terminals`.

  Owns the `:tmux_adapter` env read (with the production `Tmux` default) so
  preview modules never carry a compile-time core-module default.
  """

  @behaviour Casein.Previews.Deps.Terminals

  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxTopology

  @impl true
  def list_sessions, do: adapter().list_sessions()

  @impl true
  def list_session_panes(session), do: adapter().list_session_panes(session)

  @impl true
  def capture_scrollback(session, opts), do: adapter().capture_scrollback(session, opts)

  # Naming helpers live on Tmux/TmuxPolicy, not the swappable adapter. Call sites
  # historically used Tmux.workspace_session_prefix/1 directly (not tmux_adapter())
  # so FakeTmuxAdapter tests keep working.
  @impl true
  def workspace_session_prefix(workspace_name),
    do: Tmux.workspace_session_prefix(workspace_name)

  @impl true
  def session_name(workspace_name, sid), do: Tmux.session_name(workspace_name, sid)

  @impl true
  def topology_subscribe(session), do: TmuxTopology.subscribe(session)

  @impl true
  def topology_refresh(session), do: TmuxTopology.refresh(session)

  @impl true
  def topology_get(session, opts), do: TmuxTopology.get(session, opts)

  @impl true
  def kill_pane(session, pane_id), do: adapter().kill_pane(session, pane_id)

  @impl true
  def split_pane(session, pane_id, direction, opts),
    do: adapter().split_pane(session, pane_id, direction, opts)

  @impl true
  def select_pane(session, pane_id), do: adapter().select_pane(session, pane_id)

  @impl true
  def adapter do
    Application.get_env(:casein, :tmux_adapter, Tmux)
  end
end
