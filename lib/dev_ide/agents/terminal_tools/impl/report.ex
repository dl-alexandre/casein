defmodule DevIDE.Agents.TerminalTools.Impl.Report do
  @moduledoc false

  alias DevIDE.Agents.PaneEnv
  alias DevIDE.Audit
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Runtimes
  alias DevIDE.Runtimes.Runtime
  alias DevIDE.Terminals.SessionDirectory
  alias DevIDE.Workspaces.State

  import DevIDE.Agents.TerminalTools.Impl.Shared

  @doc "Report an agent-created Git worktree for workspace-local UX."
  @spec report_worktree(map()) :: {:ok, map()} | {:error, term()}
  def report_worktree(params) do
    case workspace_id(params) do
      id when is_binary(id) ->
        with {:ok, runtime} <- Runtimes.observe_worktree(id, params),
             :ok <- refresh_reported_worktree_env(runtime, params) do
          :ok = SessionDirectory.refresh_worktrees(id)
          {:ok, %{workspace_id: id, worktree: Runtimes.payload(runtime)}}
        end

      _ ->
        {:error, :workspace_id_required}
    end
  end

  @doc """
  Record a pre-push gate run verdict as a durable `gate.passed` /
  `gate.failed` audit row. Called (fail-open) by scripts/pre-push-check.sh;
  the MCP layer additionally persists the tool call itself since gate_report
  is classified mutating in `DevIDE.Agents.MCPAudit`.
  """
  @spec gate_report(map()) :: {:ok, map()} | {:error, term()}
  def gate_report(params) do
    with {:ok, workspace_id} <- workspace_id_arg(params),
         {:ok, passed} <- gate_passed_arg(params) do
      action = if passed, do: "gate.passed", else: "gate.failed"

      _ =
        Audit.emit!(%{
          workspace_id: workspace_id,
          actor_id: "pre_push_gate",
          action: action,
          source: "gate",
          target_type: "git_sha",
          target_ref: string_param(params, "sha"),
          metadata: gate_metadata(params)
        })

      {:ok, %{workspace_id: workspace_id, action: action, recorded: true}}
    end
  end

  # `false` is a legitimate (and load-bearing) value — no `||` fallback here.
  defp gate_passed_arg(params) do
    cond do
      is_boolean(Map.get(params, "passed")) -> {:ok, Map.get(params, "passed")}
      is_boolean(Map.get(params, :passed)) -> {:ok, Map.get(params, :passed)}
      true -> {:error, :passed_required}
    end
  end

  defp gate_metadata(params) do
    %{
      branch: string_param(params, "branch"),
      sha: string_param(params, "sha"),
      duration_s: number_param(params, "duration_s"),
      # Free text destined for a persisted row — redact like every other
      # exported string.
      failed_step: redact(string_param(params, "failed_step"))
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp number_param(params, key) do
    case Map.get(params, key) do
      value when is_number(value) -> value
      _ -> nil
    end
  end

  defp redact(value) when is_binary(value), do: Sanitizer.redact_text(value)
  defp redact(value), do: value

  defp refresh_reported_worktree_env(%Runtime{} = runtime, params) do
    case string_param(params, "tmux_session_id") do
      nil ->
        :ok

      _reported_session ->
        tmux_session = runtime.tmux_session_id
        workspace = runtime_env_workspace(runtime)

        PaneEnv.ensure_for_session(tmux_session, workspace, checkout: runtime.worktree_path)
    end
  end

  defp runtime_env_workspace(%Runtime{} = runtime) do
    base =
      case State.get(runtime.workspace_id) do
        {:ok, record} ->
          %{
            id: record.external_id,
            name: record.name || record.external_id,
            path: record.host_path
          }

        :error ->
          %{id: runtime.workspace_id, name: runtime.workspace_id, path: nil}
      end

    %{base | path: runtime.worktree_path || base.path}
  end
end
