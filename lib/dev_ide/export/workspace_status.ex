defmodule DevIDE.Export.WorkspaceStatus do
  @moduledoc """
  Builds the API status payload for a single workspace from already-persisted
  state plus cheap live reads (git status, active run snapshot).

  This module emits **summaries**, not raw artifacts:
    * No manager_payload, env, or DATABASE_URL.
    * No file contents.
    * No terminal scrollback.
    * Command output is included only via the persisted, capped snapshot.
    * Proposal diffs are NOT included; only metadata + analysis risk.
  """

  alias DevIDE.Agents.MCPUrls
  alias DevIDE.Audit
  alias DevIDE.Deployment.{Health, Registry}
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Git
  alias DevIDE.Proposals
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runtimes
  alias DevIDE.Workspaces.State
  alias DevIDE.Workspaces.State.WorkspaceRecord

  @recent_runs 10
  @recent_audit 20
  @recent_proposals 10

  @spec list_summary() :: [map()]
  def list_summary do
    State.list()
    |> Enum.map(&summary/1)
  end

  @spec status(String.t()) :: {:ok, map()} | :error
  def status(external_id) when is_binary(external_id) do
    case State.get(external_id) do
      {:ok, record} ->
        {mode, mode_source} = State.mode_for(external_id)

        payload =
          %{
            workspace: summary(record),
            mode: %{value: mode, source: mode_source},
            db_isolation: db_isolation_payload(record),
            git: git_summary(record),
            agent_capabilities: agent_capabilities(record),
            runtimes: runtime_summary(external_id),
            active_run: active_run_summary(external_id),
            recent_runs: recent_runs(external_id),
            recent_proposals: recent_proposals(record),
            recent_audit: recent_audit(external_id),
            deploy: deploy_summary()
          }
          |> Sanitizer.scrub()

        {:ok, payload}

      :error ->
        :error
    end
  end

  def status(_), do: :error

  @spec runs(String.t()) :: {:ok, [map()]} | :error
  def runs(external_id) do
    case State.get(external_id) do
      {:ok, _record} -> {:ok, recent_runs(external_id, 50)}
      :error -> :error
    end
  end

  @spec run(String.t(), String.t()) :: {:ok, map()} | :error
  def run(external_id, run_id) when is_binary(external_id) and is_binary(run_id) do
    with {:ok, _record} <- State.get(external_id),
         {:ok, summary} <- Ledger.summary_for(external_id, run_id) do
      payload =
        %{
          id: run_id,
          workspace_id: external_id,
          summary: summary,
          artifacts: run_artifacts(summary),
          timeline:
            external_id
            |> Ledger.timeline_for(run_id)
            |> Enum.map(&ledger_event_payload/1)
        }
        |> Sanitizer.scrub()

      {:ok, payload}
    else
      _ -> :error
    end
  end

  def run(_, _), do: :error

  @spec proposals(String.t()) :: {:ok, [map()]} | :error
  def proposals(external_id) do
    case State.get(external_id) do
      {:ok, record} -> {:ok, recent_proposals(record, 50)}
      :error -> :error
    end
  end

  @spec audit(String.t()) :: {:ok, [map()]} | :error
  def audit(external_id) do
    case State.get(external_id) do
      {:ok, _record} -> {:ok, recent_audit(external_id, 200)}
      :error -> :error
    end
  end

  ## Builders

  defp deploy_summary do
    revision = Registry.version()
    health = Health.status(version: revision)

    %{
      running_revision: revision,
      ok: health.ok,
      checks: health.checks,
      socket_path: health.socket_path,
      current_socket: health.current_socket
    }
  end

  defp summary(%WorkspaceRecord{} = r) do
    %{
      id: r.external_id,
      name: r.name,
      status: r.status,
      host_path_present: not is_nil(r.host_path),
      manager_last_seen_at: r.last_seen_at && DateTime.to_iso8601(r.last_seen_at)
    }
  end

  defp db_isolation_payload(%WorkspaceRecord{} = r) do
    %{
      isolation: r.db_isolation || "unknown",
      source: r.db_isolation_source || "none",
      redacted_summary: r.db_isolation_summary,
      detected_at: r.db_isolation_detected_at && DateTime.to_iso8601(r.db_isolation_detected_at)
    }
  end

  defp git_summary(%WorkspaceRecord{host_path: nil}), do: %{available: false}

  defp git_summary(%WorkspaceRecord{host_path: path}) do
    case Git.status_short(path) do
      {:ok, entries} ->
        %{
          available: true,
          changed_files: length(entries),
          entries: Enum.take(entries, 50)
        }

      _ ->
        %{available: false}
    end
  end

  defp agent_capabilities(%WorkspaceRecord{} = record) do
    workspace = %{
      id: record.external_id,
      name: record.name,
      path: record.host_path,
      metadata: record.manager_payload || %{}
    }

    workspace
    |> DevIDE.WorkspaceSource.detect_capabilities(record.host_path)
    |> Enum.map(&capability_payload(&1, record.external_id))
  end

  defp capability_payload(capability, workspace_id) do
    %{
      kind: stringify(capability.kind),
      status: stringify(capability.status),
      source: stringify(capability.source),
      path: capability.path,
      url: capability_url(capability, workspace_id),
      mtime: capability.mtime && NaiveDateTime.to_iso8601(capability.mtime),
      details: capability_details(capability, workspace_id)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp capability_url(%{kind: :preview_mcp}, workspace_id), do: MCPUrls.preview_url(workspace_id)

  defp capability_url(%{kind: :terminal_mcp}, workspace_id),
    do: MCPUrls.terminal_url(workspace_id)

  defp capability_url(capability, _workspace_id), do: capability.url

  defp capability_details(%{kind: kind, details: details}, workspace_id)
       when kind in [:preview_mcp, :terminal_mcp] do
    (details || %{})
    |> Map.put(:workspace_id, workspace_id)
    |> Map.put(:pre_scoped, true)
    |> sanitize_capability_details()
  end

  defp capability_details(capability, _workspace_id),
    do: sanitize_capability_details(capability.details || %{})

  defp sanitize_capability_details(details) when is_map(details) do
    details
    |> Enum.reject(fn {key, _value} -> key in [:absolute, "absolute"] end)
    |> Map.new(fn {key, value} -> {key, sanitize_capability_details(value)} end)
  end

  defp sanitize_capability_details(list) when is_list(list),
    do: Enum.map(list, &sanitize_capability_details/1)

  defp sanitize_capability_details(value), do: value

  # Batch command runs were retired with the delegated-execution stack; there
  # is no longer an in-flight run process to summarize.
  defp active_run_summary(_external_id), do: nil

  defp runtime_summary(external_id) do
    external_id
    |> then(&Runtimes.list_runtimes(%{"workspace_id" => &1}))
    |> Enum.map(fn runtime ->
      %{
        id: runtime.id,
        host: runtime.host_id,
        os: runtime.os,
        repo: runtime.repo,
        branch: runtime.branch,
        runtime_path: runtime.worktree_path,
        tmux_session_id: runtime.tmux_session_id,
        isolation_mode: runtime.isolation_mode,
        status: runtime.status,
        active_assignments: runtime.active_assignments,
        concurrency_limit: runtime.concurrency_limit,
        heartbeat_at: runtime.heartbeat_at && DateTime.to_iso8601(runtime.heartbeat_at),
        expired_at: runtime.expired_at && DateTime.to_iso8601(runtime.expired_at)
      }
    end)
  end

  defp recent_runs(external_id, limit \\ @recent_runs) do
    Ledger.recent_runs_for(external_id, limit)
  end

  defp recent_proposals(record, limit \\ @recent_proposals)
  defp recent_proposals(%WorkspaceRecord{host_path: nil}, _limit), do: []

  defp recent_proposals(%WorkspaceRecord{host_path: path}, limit) do
    Proposals.discover(path)
    |> Enum.take(limit)
    |> Enum.map(fn p ->
      analysis =
        case Proposals.parse(path, p.rel_path) do
          {:ok, parsed} -> Proposals.ConflictAnalyzer.analyze(path, parsed)
          _ -> %Proposals.Analysis{risk: :invalid}
        end

      %{
        path: p.rel_path,
        size: p.size,
        mtime: p.mtime && NaiveDateTime.to_iso8601(p.mtime),
        risk: analysis.risk,
        files_count: analysis.files_count,
        overlapping_files: analysis.overlapping_files
      }
    end)
  end

  defp recent_audit(external_id, limit \\ @recent_audit) do
    Audit.recent_for(external_id, limit)
    |> Enum.map(fn e ->
      %{
        id: e.id,
        action: e.action,
        target_type: e.target_type,
        target_ref: e.target_ref,
        decision: e.decision,
        reason: e.reason,
        ledger: Ledger.ledger_event?(e),
        run_id: ledger_run_id(e),
        inserted_at: DateTime.to_iso8601(e.inserted_at)
      }
    end)
  end

  defp ledger_run_id(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "run_id") || Map.get(metadata, :run_id)
  end

  defp ledger_run_id(_), do: nil

  @spec run_artifacts(map()) :: [map()]
  def run_artifacts(_summary), do: []

  defp ledger_event_payload(event) do
    %{
      id: event.id,
      action: event.action,
      noun: ledger_meta(event, "noun"),
      target_type: event.target_type,
      target_ref: event.target_ref,
      actor_id: event.actor_id,
      decision: event.decision,
      reason: event.reason,
      metadata: event.metadata || %{},
      inserted_at: DateTime.to_iso8601(event.inserted_at)
    }
  end

  defp ledger_meta(%{metadata: metadata}, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(metadata, key)
  end

  defp ledger_meta(_, _), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value
end
