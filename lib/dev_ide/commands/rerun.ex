defmodule DevIDE.Commands.Rerun do
  @moduledoc """
  Narrow API-facing command rerun boundary.

  This module accepts only a workspace id and allowlisted command id. It never
  accepts argv and delegates execution to `DevIDE.Commands.Run`, which resolves
  argv from `DevIDE.Commands.allowlist/0`.
  """

  alias DevIDE.Audit
  alias DevIDE.Commands.Run
  alias DevIDE.Policy
  alias DevIDE.Policy.Decision
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.WorkspaceRecord

  @actor_id "jx"

  @spec start(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start(workspace_id, command_id, opts \\ [])

  def start(workspace_id, command_id, opts)
      when is_binary(workspace_id) and is_binary(command_id) do
    with {:ok, %WorkspaceRecord{} = record} <- State.get(workspace_id),
         %Decision{} = decision <- policy_decision(record, command_id),
         :ok <- audit_decision(decision, record, command_id, opts),
         true <- Decision.allow?(decision),
         {:ok, root} <- host_path(record),
         {:ok, pid} <- Run.start(workspace_id, root, command_id, run_opts(opts)),
         snapshot <- Run.state(pid) do
      {:ok, run_payload(snapshot)}
    else
      :error -> {:error, :not_found}
      false -> {:error, {:policy_denied, :run_command}}
      {:error, _reason} = error -> error
    end
  end

  def start(_workspace_id, _command_id, _opts), do: {:error, :invalid_attrs}

  defp policy_decision(%WorkspaceRecord{} = record, command_id) do
    Policy.can_run_command?(%{
      workspace_id: record.external_id,
      command_id: command_id,
      db_isolation: db_isolation(record.db_isolation),
      actor_type: :jx
    })
  end

  defp audit_decision(%Decision{} = decision, %WorkspaceRecord{} = record, command_id, opts) do
    _ =
      Audit.emit_decision(decision, %{
        workspace_id: record.external_id,
        actor_id: Keyword.get(opts, :actor_id, @actor_id),
        action: if(Decision.allow?(decision), do: "command.started", else: nil),
        target_type: "command",
        target_ref: command_id,
        metadata: %{
          source: "api",
          trigger: "jx",
          command_id: command_id,
          db_isolation: record.db_isolation || "unknown"
        }
      })

    if Decision.allow?(decision), do: :ok, else: {:error, decision.reason}
  end

  defp host_path(%WorkspaceRecord{host_path: path}) when is_binary(path) and path != "",
    do: {:ok, path}

  defp host_path(_record), do: {:error, :no_root}

  defp run_opts(opts) do
    [
      actor_id: Keyword.get(opts, :actor_id, @actor_id),
      metadata: %{
        source: "api",
        trigger: "jx"
      }
    ]
  end

  defp run_payload(snapshot) do
    %{
      id: snapshot.run_id,
      workspace_id: snapshot.workspace_id,
      command_id: snapshot.id,
      status: Atom.to_string(snapshot.status),
      started_at: snapshot.started_at && DateTime.to_iso8601(snapshot.started_at),
      finished_at: snapshot.finished_at && DateTime.to_iso8601(snapshot.finished_at),
      exit_code: snapshot.exit_code
    }
  end

  defp db_isolation("shared_stage"), do: :shared_stage
  defp db_isolation("unsafe"), do: :unsafe
  defp db_isolation("ephemeral"), do: :ephemeral
  defp db_isolation("local"), do: :local
  defp db_isolation(_value), do: :unknown
end
