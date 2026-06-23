defmodule DevIdeWeb.WorkspaceLive.Show.Context do
  # Cross-cutting socket helpers shared between DevIdeWeb.WorkspaceLive.Show and
  # its extracted handle_event delegation modules (PaletteEvents, FileEvents,
  # RunEvents). Moved verbatim from Show — pure functions of the
  # socket, no behavior change. `import` this module to call them unqualified.
  @moduledoc false

  import Phoenix.Component

  alias DevIDE.Audit

  @doc "Host filesystem root for the selected terminal context, or :error when unavailable."
  def context_host_path(%{assigns: %{terminal_context: %{root_path: root}}})
      when is_binary(root) and root != "",
      do: {:ok, root}

  def context_host_path(socket), do: home_host_path(socket)

  @doc "Host filesystem root for the workspace home checkout, or :error when unavailable."
  def home_host_path(%{assigns: %{host_path: {:ok, root}}}), do: {:ok, root}
  def home_host_path(_), do: :error

  @doc "Host location descriptor for the selected terminal context, or :error when unavailable."
  def context_host_loc(%{assigns: %{host_loc: {:ok, {:local, _home}}}} = socket) do
    case context_host_path(socket) do
      {:ok, root} -> {:ok, {:local, root}}
      :error -> :error
    end
  end

  def context_host_loc(%{assigns: %{host_loc: {:ok, loc}}}), do: {:ok, loc}
  def context_host_loc(_), do: :error

  @doc "Host location descriptor for the workspace home checkout, or :error when unavailable."
  def home_host_loc(%{assigns: %{host_loc: {:ok, loc}}}), do: {:ok, loc}
  def home_host_loc(_), do: :error

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

  @doc "The current actor's id from the socket, or nil."
  def current_actor_id(socket), do: (socket.assigns[:current_user] || %{}) |> Map.get(:id)

  @doc "Human-readable message for a file-access error reason."
  def format_file_error(:too_large), do: "File too large."
  def format_file_error(:binary), do: "Binary content — refused."
  def format_file_error(:not_a_file), do: "Not a regular file."
  def format_file_error(:outside_root), do: "Path outside workspace root."
  def format_file_error(:symlink_escape), do: "Symlink escapes workspace root."
  def format_file_error(:conflict), do: "Conflict: file changed on disk."
  def format_file_error(other), do: "Error: #{inspect(other)}"
end
