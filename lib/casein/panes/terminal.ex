defmodule Casein.Panes.Terminal do
  @moduledoc """
  `Casein.Panes.Pane` implementation for classic terminal panes.

  A thin adapter over the existing terminal machinery rather than a rewrite. Terminal
  panes are created by the standard tmux split + `send_command` steps in the
  execute/reconcile pipeline, and rendered server-side by `PaneWorker` + the LiveView
  terminal component once the pane is shown. So:

    * `attach/2` is a **no-op acknowledgment** — the terminal already exists by the
      time the pipeline would call it; there is no separate backend to start.
    * `render_payload/1`, `handle_input/2` and `set_active/2` remain served by the
      LiveView terminal component + `PaneWorker` (the web layer drives focused-viewer
      sizing directly). They are optional callbacks this increment and are not routed
      through core — core cannot reference the web layer, and that boundary is
      deliberately preserved.

  `pane_ref` for a terminal is the tmux pane id; teardown additionally needs the tmux
  session, so `terminate/1` accepts `{session, pane_id}`.
  """

  @behaviour Casein.Panes.Pane

  @impl true
  def attach(_node, ctx) do
    case ctx[:pane_id] do
      pane_id when is_binary(pane_id) and pane_id != "" -> {:ok, pane_id}
      # No pane id yet (e.g. root window pane allocated by new_window): the standard
      # pipeline steps own creation, so there is nothing to attach.
      _ -> {:ok, nil}
    end
  end

  @impl true
  def serialize(node) when is_map(node) do
    %{"type" => "terminal"}
    |> put_optional("command", field(node, :command))
    |> put_optional("cwd", field(node, :cwd))
  end

  @impl true
  def terminate({session, pane_id}) when is_binary(session) and is_binary(pane_id) do
    _ = tmux_adapter().kill_pane(session, pane_id)
    :ok
  end

  # Terminal teardown without session context is owned by the existing tmux/LiveView
  # path; nothing to do here.
  def terminate(_ref), do: :ok

  # Terminal focus drives focused-viewer PTY sizing, but that path lives in the web
  # layer (LiveView component → PaneWorker.set_active/2) and core must not call into
  # it. This stays a no-op; the web layer keeps owning terminal focus directly.
  @impl true
  def set_active(_ref, active?) when is_boolean(active?), do: :ok

  # Terminal panes are served by `PaneWorker`, not a registry, so there is no
  # list to fold into `Casein.Panes.snapshot/1`. Present for the facade's
  # `function_exported?` probe; it never carries renderable terminal state.
  @impl true
  def list(_workspace_id), do: []

  # --- internals ---------------------------------------------------------------

  defp tmux_adapter do
    Application.get_env(:casein, :tmux_adapter, Casein.Terminals.Tmux)
  end

  defp field(node, key), do: Map.get(node, key, Map.get(node, to_string(key)))

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, ""), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
