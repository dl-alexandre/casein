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

  alias DevIDE.Agents.{MCPUrls, TidewaveMCP}
  alias DevIDE.Previews.EnvRegistry
  alias DevIDE.Audit
  alias DevIDE.Deployment.{Health, Registry}
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Git
  alias DevIDE.PreviousSessions
  alias DevIDE.Proposals
  alias DevIDE.Runs.Ledger
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.AgentPane
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.SessionSummary

  @recent_runs 10
  @recent_audit 20
  @recent_proposals 10

  @spec list_summary() :: [map()]
  def list_summary do
    Workspaces.list_records()
    |> Enum.map(&summary/1)
  end

  @spec status(String.t()) :: {:ok, map()} | :error
  def status(external_id) when is_binary(external_id) do
    case Workspaces.get_record(external_id) do
      {:ok, record} ->
        {mode, mode_source} = Workspaces.mode_for(external_id)

        workspace_map = workspace_map(record)
        session_summary = session_summary(record)

        payload =
          %{
            workspace: summary(record),
            mode: %{value: mode, source: mode_source},
            db_isolation: db_isolation_payload(record),
            git: git_summary(record),
            agent_capabilities: agent_capabilities(record),
            preview_environments: preview_environments_payload(),
            tidewave_mcp_url: TidewaveMCP.resolve_url(workspace_map),
            runtimes: runtime_summary(external_id),
            agent_sessions: agent_sessions(session_summary),
            agent_layout: agent_layout(session_summary),
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
    case Workspaces.get_record(external_id) do
      {:ok, _record} -> {:ok, recent_runs(external_id, 50)}
      :error -> :error
    end
  end

  @spec run(String.t(), String.t()) :: {:ok, map()} | :error
  def run(external_id, run_id) when is_binary(external_id) and is_binary(run_id) do
    with {:ok, _record} <- Workspaces.get_record(external_id),
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
    case Workspaces.get_record(external_id) do
      {:ok, record} -> {:ok, recent_proposals(record, 50)}
      :error -> :error
    end
  end

  @spec audit(String.t()) :: {:ok, [map()]} | :error
  def audit(external_id) do
    case Workspaces.get_record(external_id) do
      {:ok, _record} -> {:ok, recent_audit(external_id, 200)}
      :error -> :error
    end
  end

  @spec previous_sessions(String.t(), keyword()) :: {:ok, map()} | :error
  def previous_sessions(external_id, opts \\ []) do
    case Workspaces.get_record(external_id) do
      {:ok, record} ->
        payload =
          external_id
          |> PreviousSessions.search(previous_session_opts(record, opts))
          |> sanitize_previous_sessions()
          |> redact_text_values()

        {:ok, payload}

      :error ->
        :error
    end
  end

  @previous_session_preview_keys [
    :agent_action,
    :agent_session,
    :agent_pane,
    :tool,
    :session_id,
    :pane,
    :title,
    :status,
    :url,
    :source_url,
    :display_url,
    :screenshot_url,
    :artifact_url,
    :recording_id,
    :recording_url,
    :recording_path,
    :recording_status,
    :path,
    :port,
    :surface,
    :mode,
    :element_id,
    :selector
  ]

  defp sanitize_previous_sessions(%{results: results} = payload) when is_list(results) do
    payload
    |> Map.update!(:results, fn results ->
      Enum.map(results, fn result -> sanitize_previous_session_result(result) end)
    end)
  end

  defp sanitize_previous_sessions(payload), do: Sanitizer.scrub(payload)

  defp previous_session_opts(record, opts) do
    record_aliases = workspace_aliases(record)

    Keyword.update(opts, :workspace_aliases, record_aliases, fn aliases ->
      [aliases | record_aliases]
    end)
  end

  defp workspace_aliases(record) do
    [record.external_id, record.name]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp sanitize_previous_session_result(%{} = result) do
    result
    |> Map.update(:metadata, %{}, &Sanitizer.scrub/1)
    |> Map.update(:preview, nil, &sanitize_previous_session_preview/1)
  end

  defp sanitize_previous_session_result(result), do: Sanitizer.scrub(result)

  defp sanitize_previous_session_preview(%{} = preview) do
    @previous_session_preview_keys
    |> Enum.reduce(%{}, fn key, acc ->
      case preview_value(preview, key) do
        nil -> acc
        "" -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp sanitize_previous_session_preview(_preview), do: nil

  defp preview_value(preview, key) do
    Map.get(preview, key) || Map.get(preview, Atom.to_string(key))
  end

  defp redact_text_values(%DateTime{} = value), do: value
  defp redact_text_values(%NaiveDateTime{} = value), do: value
  defp redact_text_values(%Date{} = value), do: value
  defp redact_text_values(%Time{} = value), do: value

  defp redact_text_values(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, redact_text_values(child)} end)
  end

  defp redact_text_values(value) when is_list(value), do: Enum.map(value, &redact_text_values/1)
  defp redact_text_values(value) when is_binary(value), do: Sanitizer.redact_text(value)
  defp redact_text_values(value), do: value

  ## Builders

  defp deploy_summary do
    revision = Registry.version()
    health = Health.status(version: revision)

    %{
      running_revision: revision,
      ok: health.ok,
      checks: health.checks,
      socket_path: health.socket_path,
      current_socket: health.current_socket,
      last_deploy: health.last_deploy
    }
  end

  defp summary(r) do
    %{
      id: r.external_id,
      name: r.name,
      status: r.status,
      host_path_present: not is_nil(r.host_path),
      manager_last_seen_at: r.last_seen_at && DateTime.to_iso8601(r.last_seen_at)
    }
  end

  defp db_isolation_payload(r) do
    %{
      isolation: r.db_isolation || "unknown",
      source: r.db_isolation_source || "none",
      redacted_summary: r.db_isolation_summary,
      detected_at: r.db_isolation_detected_at && DateTime.to_iso8601(r.db_isolation_detected_at)
    }
  end

  defp git_summary(%{host_path: nil}), do: %{available: false}

  defp git_summary(%{host_path: path}) do
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

  defp workspace_map(record) do
    %{
      id: record.external_id,
      name: record.name,
      path: record.host_path,
      metadata: record.manager_payload || %{}
    }
  end

  defp agent_capabilities(record) do
    record
    |> workspace_map()
    |> DevIDE.WorkspaceSource.detect_capabilities(record.host_path)
    |> Enum.map(&capability_payload(&1, record.external_id))
  end

  defp preview_environments_payload do
    EnvRegistry.running_instances()
    |> Enum.map(fn inst ->
      %{
        id: inst["id"],
        ref: inst["ref"],
        port: inst["port"],
        kind: inst["kind"],
        started_at: inst["started_at"],
        tidewave_url: EnvRegistry.tidewave_url(inst),
        tidewave_mcp_url: EnvRegistry.tidewave_mcp_url(inst)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
    end)
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

  defp capability_url(%{kind: :artifact_mcp}, workspace_id),
    do: MCPUrls.artifact_url(workspace_id)

  defp capability_url(capability, _workspace_id), do: capability.url

  defp capability_details(%{kind: kind, details: details}, workspace_id)
       when kind in [:preview_mcp, :terminal_mcp, :artifact_mcp] do
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

  defp session_summary(record) do
    SessionSummary.build(record)
  rescue
    _ -> %{sessions: []}
  catch
    :exit, _ -> %{sessions: []}
  end

  defp agent_sessions(session_summary) do
    session_summary
    |> Map.get(:sessions, [])
    |> Enum.filter(&agent_session_summary?/1)
    |> Enum.take(10)
    |> Enum.map(&agent_session_payload/1)
  end

  defp agent_layout(session_summary) do
    session_summary
    |> Map.get(:sessions, [])
    |> AgentPane.layout_status()
  rescue
    _ -> AgentPane.layout_status([])
  catch
    :exit, _ -> AgentPane.layout_status([])
  end

  defp agent_session_summary?(session) do
    present?(Map.get(session, :agent_status)) or present?(Map.get(session, :agent))
  end

  defp agent_session_payload(session) do
    %{
      id: Map.get(session, :id),
      label: Map.get(session, :label),
      title: Map.get(session, :agent_title) || Map.get(session, :title),
      status: Map.get(session, :agent_status),
      tmux_session: Map.get(session, :tmux_session),
      pane: Map.get(session, :agent_pane),
      href: Map.get(session, :href),
      preview_pane_ids: Map.get(session, :preview_pane_ids, [])
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp recent_runs(external_id, limit \\ @recent_runs) do
    Ledger.recent_runs_for(external_id, limit)
  end

  defp recent_proposals(record, limit \\ @recent_proposals)
  defp recent_proposals(%{host_path: nil}, _limit), do: []

  defp recent_proposals(%{host_path: path}, limit) do
    Proposals.discover(path)
    |> Enum.take(limit)
    |> Enum.map(fn p ->
      analysis =
        case Proposals.parse(path, p.rel_path) do
          {:ok, parsed} -> Proposals.analyze(path, parsed)
          _ -> Proposals.invalid_analysis()
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
