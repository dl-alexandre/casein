defmodule DevIdeWeb.WorkspaceLive.Show.Context do
  # Cross-cutting socket helpers shared between DevIdeWeb.WorkspaceLive.Show and
  # its extracted handle_event delegation modules (PaletteEvents, FileEvents,
  # RunEvents, AgentEvents). Moved verbatim from Show — pure functions of the
  # socket, no behavior change. `import` this module to call them unqualified.
  @moduledoc false

  import Phoenix.Component

  alias DevIDE.Audit

  @doc "Host filesystem root for the workspace, or :error when unavailable."
  def host_path(%{assigns: %{host_path: {:ok, root}}}), do: {:ok, root}
  def host_path(_), do: :error

  @doc "Host location descriptor for the workspace, or :error when unavailable."
  def host_loc(%{assigns: %{host_loc: {:ok, loc}}}), do: {:ok, loc}
  def host_loc(_), do: :error

  @doc """
  Builds the `DevIDE.Policy` decision context from the socket, merging any
  per-action `extra` (e.g. `%{command_id: id}`).
  """
  def policy_ctx(socket, extra \\ %{}) do
    user = socket.assigns[:current_user] || %{}
    ws = socket.assigns.workspace

    base = %{
      workspace_id: ws.id,
      workspace_user: Map.get(ws, :user),
      workspace_mode_source: socket.assigns[:workspace_mode_source],
      actor_username: Map.get(user, :username) || Map.get(user, :id),
      actor_id: Map.get(user, :id),
      actor_role: Map.get(user, :role) || Map.get(user, "role"),
      db_isolation: (socket.assigns[:db_isolation] || %{}) |> Map.get(:isolation)
    }

    Map.merge(base, extra)
  end

  @doc """
  Runs a policy decision, emits the audit event, stores it on the socket as
  `:last_decision`, and returns `{decision, socket}`. Callers funnel sensitive
  actions through here before mutating state.
  """
  def gate(socket, decision_fun, audit_attrs) do
    decision = decision_fun.()
    attrs = Map.put_new(audit_attrs, :workspace_id, socket.assigns.workspace.id)
    _ = Audit.emit_decision(decision, attrs)
    socket = assign(socket, :last_decision, decision)

    {decision, socket}
  end
end
