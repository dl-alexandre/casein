defmodule CaseinWeb.WorkspaceLive.Show.PanelGate do
  # Viewer-authorization gate shared by the Show LiveView's :handle_event
  # hook and the panel LiveComponents. LiveComponent events bypass the LV's
  # attach_hook, so any panel that owns its own handle_event MUST call
  # gate_event/3 — this module is the single implementation of the check and
  # of the audited denial; do not copy it into components.
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import CaseinWeb.WorkspaceLive.Show.Context, only: [policy_ctx: 1]

  alias Casein.Audit
  alias Casein.Policy
  alias Casein.Workspaces

  @doc """
  Runs `fun` when the viewer may access the workspace; otherwise emits the
  audited denial, stores it as `:last_decision`, and asks the parent LV to
  flash (components cannot render root flash themselves).

  Works for both LV and LiveComponent sockets: it only reads assigns
  (`:workspace`, `:current_user`).
  """
  def gate_event(socket, event, fun) do
    if viewer_authorized?(socket.assigns) do
      fun.()
    else
      decision = emit_forbidden(socket, event)
      send(self(), {:panel_flash, :error, "You do not have access to this workspace."})
      {:noreply, assign(socket, :last_decision, decision)}
    end
  end

  def viewer_authorized?(assigns) do
    user = assigns[:current_user] || %{}
    ws = assigns[:workspace]

    path_access_pre_authorized?() or
      (is_map(ws) and Workspaces.viewer_can_access_workspace?(ws, user))
  end

  @doc """
  Whether this deployment pre-authorizes workspace access without a viewer
  check. Keyed on deployment mode, never on URL shape — the same trust rule
  that gates path-route emission (`WorkspaceRoutes.path_routes_trusted?/0`):
  trusted only in LAN mode, and LAN trust never overrides forward auth.
  """
  def path_access_pre_authorized? do
    CaseinWeb.WorkspaceRoutes.path_routes_trusted?()
  end

  @doc "Builds + audits the :forbidden denial for a UI event; returns the decision."
  def emit_forbidden(socket, event), do: emit_denial(socket, event, :forbidden)

  @doc "Builds + audits the :unknown_action denial for a UI event; returns the decision."
  def emit_unknown(socket, event), do: emit_denial(socket, event, :unknown_action)

  defp emit_denial(socket, event, reason) do
    ctx = policy_ctx(socket)
    decision = Policy.Decision.deny(:ui_event, Policy.mode(ctx), reason, %{event: event})

    _ =
      Audit.emit_decision(decision, %{
        target_type: "ui_event",
        target_ref: event,
        actor_id: ctx.actor_id,
        workspace_id: socket.assigns.workspace.id,
        metadata: %{event: event}
      })

    decision
  end
end
