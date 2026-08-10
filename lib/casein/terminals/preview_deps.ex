defmodule Casein.Terminals.PreviewDeps do
  @moduledoc """
  Core-side impl of `Casein.Previews.Deps.Terminals`.

  Backend-covered ops (`list_session_panes`, capture, kill/split/select pane,
  session naming) go through `Casein.Terminals.Backend`. Topology subscribe/
  list_sessions remain on the tmux adapter until those surfaces join the
  Backend behaviour. Preview modules never carry a compile-time core default.
  """

  @behaviour Casein.Previews.Deps.Terminals

  alias Casein.Terminals.Backend
  alias Casein.Terminals.Tmux
  alias Casein.Terminals.TmuxTopology

  @impl true
  def list_sessions, do: adapter().list_sessions()

  @impl true
  def list_session_panes(session), do: Backend.module().list_session_panes(session)

  @impl true
  def capture_scrollback(session, opts), do: Backend.module().capture_scrollback(session, opts)

  # Naming goes through Backend so Fake/ConPTY peers can own prefixes when
  # selected. Default Tmux backend still uses TmuxPolicy.
  @impl true
  def workspace_session_prefix(workspace_name),
    do: Backend.module().session_name(workspace_name, "")

  @impl true
  def session_name(workspace_name, sid), do: Backend.module().session_name(workspace_name, sid)

  @impl true
  def topology_subscribe(session), do: TmuxTopology.subscribe(session)

  @impl true
  def topology_refresh(session), do: TmuxTopology.refresh(session)

  @impl true
  def topology_get(session, opts), do: TmuxTopology.get(session, opts)

  @impl true
  def kill_pane(session, pane_id), do: Backend.module().kill_pane(session, pane_id)

  @impl true
  def split_pane(session, pane_id, direction, opts),
    do: Backend.module().split_pane(session, pane_id, direction, opts)

  @impl true
  def select_pane(session, pane_id), do: Backend.module().select_pane(session, pane_id)

  @impl true
  def adapter do
    Application.get_env(:casein, :tmux_adapter, Tmux)
  end
end
