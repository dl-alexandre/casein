defmodule DevIDE.Fleet.Takeover do
  @moduledoc """
  Operator takeover preparation for active executions.

  A takeover is intentionally read-first. Preparing one returns the tmux attach
  command, current pane snapshot, durable output chunks, and orchestration
  snapshot needed by an operator to manually intervene. It must not mutate the
  assignment lifecycle or execution projection.
  """

  alias DevIDE.Assignments
  alias DevIDE.Audit
  alias DevIDE.Fleet.Approvals
  alias DevIDE.Fleet.ArtifactStore
  alias DevIDE.Fleet.ExecutionProjection
  alias DevIDE.Fleet.ExecutionProjectionStore
  alias DevIDE.Policy
  alias DevIDE.Policy.Decision
  alias DevIDE.Terminals.Boundary
  alias DevIDE.Terminals.TmuxAdapter

  @type t :: %{
          assignment_id: String.t(),
          workspace_id: String.t(),
          assignment_state: String.t(),
          execution: ExecutionProjection.t(),
          tmux_session: String.t(),
          attach_command: String.t(),
          pane_snapshot: String.t(),
          historical_chunks: [map()],
          orchestration_state_unchanged?: boolean()
        }

  @type intervention :: %{
          assignment_id: String.t(),
          workspace_id: String.t(),
          assignment_state: String.t(),
          execution_id: String.t(),
          tmux_session: String.t(),
          sent: boolean(),
          orchestration_state_unchanged?: boolean()
        }

  @spec prepare(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def prepare(assignment_id, opts \\ [])

  def prepare(assignment_id, opts) when is_binary(assignment_id) do
    tmux = Keyword.get(opts, :tmux_adapter, TmuxAdapter)
    operator_id = Keyword.get(opts, :operator_id, "operator")

    with {:ok, before_assignment} <- fetch_assignment(assignment_id),
         {:ok, projection} <- active_execution(assignment_id),
         {:ok, session} <- active_tmux_session(projection, tmux),
         {:ok, pane} <- capture_pane(tmux, session),
         {:ok, after_assignment} <- fetch_assignment(assignment_id) do
      unchanged? = before_assignment == after_assignment

      Audit.emit!(%{
        action: "fleet.operator_takeover.prepared",
        actor_id: operator_id,
        workspace_id: before_assignment.workspace_id,
        target_type: "assignment",
        target_ref: assignment_id,
        decision: :allow,
        metadata: %{
          execution_id: projection.id,
          runner_id: projection.runner_id,
          tmux_session: session,
          orchestration_state: before_assignment.state,
          orchestration_state_unchanged: unchanged?
        }
      })

      {:ok,
       %{
         assignment_id: assignment_id,
         workspace_id: before_assignment.workspace_id,
         assignment_state: before_assignment.state,
         execution: projection,
         tmux_session: session,
         attach_command: tmux.attach_command(session),
         pane_snapshot: pane,
         historical_chunks: ArtifactStore.chunks(projection.id),
         orchestration_state_unchanged?: unchanged?
       }}
    end
  end

  def prepare(_assignment_id, _opts), do: {:error, :invalid_assignment_id}

  @spec send_keys(String.t(), String.t(), keyword()) :: {:ok, intervention()} | {:error, term()}
  def send_keys(assignment_id, keys, opts \\ [])

  def send_keys(assignment_id, keys, opts)
      when is_binary(assignment_id) and is_binary(keys) and keys != "" do
    tmux = Keyword.get(opts, :tmux_adapter, TmuxAdapter)
    operator_id = Keyword.get(opts, :operator_id, "operator")

    with {:ok, _approval} <-
           Approvals.require_granted(
             Keyword.get(opts, :approval_id),
             :takeover_send_keys,
             assignment_id
           ),
         {:ok, before_assignment} <- fetch_assignment(assignment_id),
         {:ok, projection} <- active_execution(assignment_id),
         {:ok, session} <- active_tmux_session(projection, tmux),
         {:ok, policy_context} <- authorize_intervention(before_assignment, session, keys, opts),
         :ok <- tmux.send_keys(session, keys),
         {:ok, after_assignment} <- fetch_assignment(assignment_id) do
      unchanged? = before_assignment == after_assignment

      Audit.emit!(%{
        action: "fleet.operator_takeover.intervened",
        actor_id: operator_id,
        workspace_id: before_assignment.workspace_id,
        target_type: "assignment",
        target_ref: assignment_id,
        decision: :allow,
        metadata: %{
          execution_id: projection.id,
          runner_id: projection.runner_id,
          tmux_session: session,
          takeover_mode: policy_context.mode,
          command_id: Map.get(policy_context, :command_id),
          orchestration_state: before_assignment.state,
          orchestration_state_unchanged: unchanged?
        }
      })

      {:ok,
       %{
         assignment_id: assignment_id,
         workspace_id: before_assignment.workspace_id,
         assignment_state: before_assignment.state,
         execution_id: projection.id,
         tmux_session: session,
         sent: true,
         orchestration_state_unchanged?: unchanged?
       }}
    end
  end

  def send_keys(_assignment_id, _keys, _opts), do: {:error, :invalid_attrs}

  defp authorize_intervention(assignment, session, keys, opts) do
    mode = opts |> Keyword.get(:mode, :governed) |> Boundary.normalize_mode()
    operator_id = Keyword.get(opts, :operator_id, "operator")

    case mode do
      :governed ->
        authorize_governed_command(assignment, session, keys, operator_id)

      :raw ->
        authorize_raw_takeover(assignment, session, opts)
    end
  end

  defp authorize_governed_command(assignment, session, keys, operator_id) do
    with {:ok, command_id} <- Boundary.resolve_command(keys),
         %Decision{} = decision <-
           Policy.can_run_command?(%{
             workspace_id: assignment.workspace_id,
             command_id: command_id,
             actor_type: :terminal
           }),
         true <- Decision.allow?(decision) || {:error, decision.reason} do
      {:ok, %{mode: :governed, command_id: command_id}}
    else
      {:error, reason} ->
        audit_denied_intervention(assignment, session, operator_id, reason, keys)
        {:error, reason}

      false ->
        audit_denied_intervention(assignment, session, operator_id, :policy_denied, keys)
        {:error, :policy_denied}
    end
  end

  defp authorize_raw_takeover(assignment, session, opts) do
    case Boundary.authorize_raw(assignment.workspace_id,
           host_id: Keyword.get(opts, :host_id),
           actor_id: Keyword.get(opts, :operator_id, "operator"),
           session_id: session
         ) do
      :ok ->
        {:ok, %{mode: :raw}}

      {:error, reason} ->
        audit_denied_intervention(
          assignment,
          session,
          Keyword.get(opts, :operator_id, "operator"),
          reason,
          "(raw)"
        )

        {:error, reason}
    end
  end

  defp audit_denied_intervention(assignment, session, operator_id, reason, keys) do
    Audit.emit!(%{
      action: "fleet.operator_takeover.denied",
      actor_id: operator_id,
      workspace_id: assignment.workspace_id,
      target_type: "assignment",
      target_ref: assignment.id,
      decision: :deny,
      reason: reason,
      metadata: %{
        tmux_session: session,
        attempted_input: audit_keys(keys)
      }
    })
  end

  defp audit_keys(keys) when is_binary(keys) and byte_size(keys) <= 256, do: keys
  defp audit_keys(keys) when is_binary(keys), do: String.slice(keys, 0, 256) <> "..."
  defp audit_keys(_keys), do: "(invalid)"

  defp active_execution(assignment_id) do
    case ExecutionProjectionStore.active_for_assignment(assignment_id) do
      {:ok, projection} -> {:ok, projection}
      :error -> {:error, :no_active_execution}
    end
  end

  defp fetch_assignment(assignment_id) do
    case Assignments.get(assignment_id) do
      {:ok, assignment} -> {:ok, assignment}
      :error -> {:error, :assignment_not_found}
    end
  end

  defp active_tmux_session(%ExecutionProjection{tmux_session: nil}, _tmux),
    do: {:error, :no_tmux_session}

  defp active_tmux_session(%ExecutionProjection{tmux_session: session}, tmux) do
    if tmux.session_alive?(session) do
      {:ok, session}
    else
      {:error, :session_not_alive}
    end
  end

  defp capture_pane(tmux, session) do
    case tmux.capture(session) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end
end
