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

  alias DevIDE.Audit
  alias DevIDE.Commands.{History, Run}
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Git
  alias DevIDE.Proposals
  alias DevIDE.Runners
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runs.Status
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
            recent_audit: recent_audit(external_id)
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
    |> Enum.map(&capability_payload/1)
  end

  defp capability_payload(capability) do
    %{
      kind: stringify(capability.kind),
      status: stringify(capability.status),
      source: stringify(capability.source),
      path: capability.path,
      url: capability.url,
      mtime: capability.mtime && NaiveDateTime.to_iso8601(capability.mtime),
      details: sanitize_capability_details(capability.details || %{})
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp sanitize_capability_details(details) when is_map(details) do
    details
    |> Enum.reject(fn {key, _value} -> key in [:absolute, "absolute"] end)
    |> Map.new(fn {key, value} -> {key, sanitize_capability_details(value)} end)
  end

  defp sanitize_capability_details(list) when is_list(list),
    do: Enum.map(list, &sanitize_capability_details/1)

  defp sanitize_capability_details(value), do: value

  defp active_run_summary(external_id) do
    with {:ok, pid} <- Run.whereis(external_id),
         snap when is_map(snap) <- Run.state(pid) do
      %{
        id: snap.run_id,
        command_id: snap.id,
        argv: snap.argv,
        status: Status.normalize(snap.status),
        started_at: snap.started_at && DateTime.to_iso8601(snap.started_at),
        finished_at: snap.finished_at && DateTime.to_iso8601(snap.finished_at),
        exit_code: snap.exit_code
      }
    else
      _ -> nil
    end
  end

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
    case Ledger.recent_runs_for(external_id, limit) do
      [] ->
        legacy_recent_runs(external_id, limit)

      runs ->
        runs
    end
  end

  defp recent_proposals(record, limit \\ @recent_proposals)
  defp recent_proposals(%WorkspaceRecord{host_path: nil}, _limit), do: []

  defp recent_proposals(%WorkspaceRecord{host_path: path}, limit) do
    Proposals.discover(path)
    |> Enum.take(limit)
    |> Enum.map(fn p ->
      analysis =
        case Proposals.parse(path, p.rel_path) do
          {:ok, parsed} -> DevIDE.Proposals.ConflictAnalyzer.analyze(path, parsed)
          _ -> %DevIDE.Proposals.Analysis{risk: :invalid}
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

  defp legacy_recent_runs(external_id, limit) do
    History.recent_for(external_id, limit)
    |> Enum.map(fn r ->
      %{
        id: r.id,
        command_id: r.command_id,
        argv: r.argv,
        status: r.status,
        exit_code: r.exit_code,
        duration_ms: r.duration_ms,
        output_truncated: r.output_truncated,
        started_at: r.started_at && DateTime.to_iso8601(r.started_at),
        finished_at: r.finished_at && DateTime.to_iso8601(r.finished_at)
      }
    end)
  end

  defp ledger_run_id(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "run_id") || Map.get(metadata, :run_id)
  end

  defp ledger_run_id(_), do: nil

  @spec run_artifacts(map()) :: [map()]
  def run_artifacts(summary) when is_map(summary) do
    []
    |> maybe_add(command_output_artifact(summary))
    |> maybe_add(assignment_artifact(summary))
    |> Enum.reverse()
  end

  def run_artifacts(_), do: []

  defp command_output_artifact(%{id: run_id}) when is_binary(run_id) do
    case History.get(run_id) do
      {:ok, record} ->
        %{
          type: "command_output",
          run_id: record.id,
          command_id: record.command_id,
          argv: record.argv,
          status: record.status,
          exit_code: record.exit_code,
          duration_ms: record.duration_ms,
          output: record.output || "",
          output_truncated: record.output_truncated,
          started_at: record.started_at && DateTime.to_iso8601(record.started_at),
          finished_at: record.finished_at && DateTime.to_iso8601(record.finished_at)
        }

      _ ->
        nil
    end
  end

  defp command_output_artifact(_), do: nil

  defp assignment_artifact(%{assignment_id: assignment_id} = summary)
       when is_binary(assignment_id) do
    case Runners.replay(assignment_id) do
      {:ok, replay} ->
        %{
          type: "runner_assignment",
          assignment_id: replay.assignment.id,
          status: replay.assignment.status,
          safe_action_id: replay.assignment.safe_action_id,
          reports_count: length(replay.reports),
          report_ids: Enum.map(replay.reports, & &1.id),
          report_events: Enum.map(replay.reports, & &1.event),
          evidence_present?: map_size(replay.assignment.evidence || %{}) > 0,
          failure_reason: replay.assignment.failure_reason,
          failure_class: Map.get(replay.assignment, :failure_class)
        }

      _ ->
        %{
          type: "runner_assignment",
          assignment_id: assignment_id,
          status: Map.get(summary, :status, "unknown")
        }
    end
  end

  defp assignment_artifact(_), do: nil

  defp maybe_add(list, nil), do: list
  defp maybe_add(list, artifact), do: [artifact | list]

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
