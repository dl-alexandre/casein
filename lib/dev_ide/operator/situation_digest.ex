defmodule DevIDE.Operator.SituationDigest do
  @moduledoc """
  Cold operator situation digest for a single workspace.

  This is a composition layer, not a new source of truth: every section is
  read from an existing read model — `DevIDE.Workspaces.SessionSummary` for
  sessions and agent layout, `DevIDE.Terminals.AgentState` for semantic pane
  states, `DevIDE.Runtimes.list_agent_worktrees/1` for agent worktrees,
  `DevIDE.Deployment.Health` for deploy status, `DevIDE.Agents.Activity` and
  `DevIDE.Audit` for recent activity. Nothing is re-derived here.

  The digest is a summary payload: free text (task summaries, agent-state
  messages, handoffs, activity summaries) is redacted through
  `DevIDE.Export.Sanitizer`, and no raw terminal scrollback is ever included.
  `risks` is filled by `DevIDE.Operator.Risks.detect/1` over the finished
  digest.
  """

  alias DevIDE.Agents.Activity
  alias DevIDE.Audit
  alias DevIDE.Deployment.Health
  alias DevIDE.Export.Sanitizer
  alias DevIDE.Operator.Risks
  alias DevIDE.Runtimes
  alias DevIDE.Terminals.AgentState
  alias DevIDE.Terminals.TmuxTopology
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.SessionSummary

  @recent_activity 20
  @recent_audit 20

  @doc """
  Build the situation digest for `workspace_id`.

  Sections degrade independently: a failing constituent read (dead tmux,
  missing workspace record, unreachable deploy poller file) empties its own
  section instead of failing the digest.
  """
  @spec build(String.t()) :: {:ok, map()} | {:error, term()}
  def build(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    now = DateTime.utc_now()
    summary = session_summary(workspace_id)
    worktrees = worktrees(workspace_id)
    deploy = deploy()
    activity = activity(workspace_id, now)

    digest =
      %{
        workspace_id: workspace_id,
        generated_at: now,
        freshness: freshness(now, worktrees, deploy, activity),
        sessions: Enum.map(Map.get(summary, :sessions, []), &session_digest(&1, now)),
        agent_layout: agent_layout(summary),
        worktrees: worktrees,
        deploy: deploy,
        activity: activity,
        risks: []
      }
      |> sanitize()

    {:ok, %{digest | risks: Risks.detect(digest)}}
  end

  def build(_workspace_id), do: {:error, :invalid_workspace_id}

  ## Sessions

  defp session_summary(workspace_id) do
    ws =
      case Workspaces.get_record(workspace_id) do
        {:ok, record} -> record
        :error -> %{id: workspace_id, name: workspace_id}
      end

    SessionSummary.build(ws)
  rescue
    _ -> %{sessions: []}
  catch
    :exit, _ -> %{sessions: []}
  end

  defp session_digest(session, now) do
    tmux_session = present(Map.get(session, :tmux_session))

    %{
      sid: Map.get(session, :id),
      tmux_session: tmux_session,
      agent_status: Map.get(session, :agent_status),
      panes: panes(tmux_session, now)
    }
    |> compact()
  end

  defp panes(nil, _now), do: []

  defp panes(tmux_session, now) do
    topology =
      tmux_session
      |> TmuxTopology.snapshot(tmux: tmux_adapter())
      |> AgentState.enrich_topology(tmux_session)

    reports = AgentState.for_session(tmux_session)

    Enum.map(topology.panes, &pane_digest(&1, reports, now))
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp pane_digest(pane, reports, now) do
    %{
      id: Map.get(pane, :id),
      window_id: Map.get(pane, :window_id),
      role: Map.get(pane, :role),
      paired: Map.get(pane, :paired),
      pane_state: Map.get(pane, :pane_state),
      agent_state: Map.get(pane, :agent_state),
      agent_state_message: Map.get(pane, :agent_state_message),
      agent_state_age_s: report_age_s(pane, reports, now),
      task_summary: Map.get(pane, :task_summary),
      current_command: Map.get(pane, :current_command),
      current_path: Map.get(pane, :current_path)
    }
    |> compact()
  end

  # Age of the explicit report backing the pane's resolved agent_state; absent
  # when the pane has no live report (heuristic-only panes carry no age).
  defp report_age_s(pane, reports, now) do
    with state when not is_nil(state) <- Map.get(pane, :agent_state),
         %{reported_at: at} <- Map.get(reports, Map.get(pane, :id)) do
      max(DateTime.diff(now, at, :second), 0)
    else
      _ -> nil
    end
  end

  defp agent_layout(summary) do
    case Map.get(summary, :agent_layout) do
      %{} = layout -> Map.take(layout, [:status, :ready, :sessions_checked])
      _ -> nil
    end
  end

  ## Worktrees

  defp worktrees(workspace_id) do
    workspace_id
    |> Runtimes.list_agent_worktrees()
    |> Enum.map(fn worktree ->
      %{
        path: Map.get(worktree, :path),
        branch: Map.get(worktree, :branch),
        head_sha: Map.get(worktree, :git_head_sha),
        dirty_count: Map.get(worktree, :dirty_count),
        status: Map.get(worktree, :worktree_status),
        exit_status: Map.get(worktree, :exit_status),
        handoff: Map.get(worktree, :handoff),
        observed_at: Map.get(worktree, :observed_at)
      }
      |> compact()
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  ## Deploy

  @doc """
  The digest's deploy section on its own — used by
  `DevIDE.Operator.SituationServer` to refresh just this section on
  `"deploy:updates"` events without a full rebuild.
  """
  @spec deploy_section() :: map()
  def deploy_section, do: deploy()

  defp deploy do
    health = Health.status()
    last_deploy = Map.get(health, :last_deploy) || %{}
    record = Map.get(last_deploy, :record) || %{}

    %{
      running_revision: Map.get(health, :version),
      drift: drift(health),
      pipeline: Map.get(last_deploy, :pipeline),
      phase: Map.get(record, "phase"),
      actionable: Map.get(last_deploy, :actionable, false),
      finished_at: Map.get(record, "finished_at"),
      started_at: Map.get(record, "started_at")
    }
  rescue
    _ -> %{running_revision: nil, drift: nil, pipeline: :unknown, phase: nil, actionable: false}
  catch
    :exit, _ ->
      %{running_revision: nil, drift: nil, pipeline: :unknown, phase: nil, actionable: false}
  end

  # true = the running revision drifts from the remote head, false = current,
  # nil = drift checking is not configured for this deployment.
  defp drift(health) do
    case get_in(health, [:checks, :deploy_revision_current]) do
      true -> false
      false -> true
      _ -> nil
    end
  end

  ## Activity

  defp activity(workspace_id, _now) do
    %{
      recent: recent_activity(workspace_id),
      last_mutation: last_mutation(workspace_id)
    }
  end

  defp recent_activity(workspace_id) do
    workspace_id
    |> Activity.recent(@recent_activity)
    |> Enum.map(fn entry ->
      %{
        tool: Map.get(entry, :tool),
        source: Map.get(entry, :source),
        summary: Map.get(entry, :summary),
        status: Map.get(entry, :status),
        at: Map.get(entry, :inserted_at)
      }
      |> compact()
    end)
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp last_mutation(workspace_id) do
    case Audit.recent_for(workspace_id, @recent_audit) do
      [event | _] ->
        %{
          action: event.action,
          target_type: event.target_type,
          target_ref: event.target_ref,
          actor_id: event.actor_id,
          at: event.inserted_at
        }
        |> compact()

      _ ->
        nil
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  ## Freshness

  # Millisecond staleness per section. Sessions and deploy health are read
  # live at build time (0); worktrees age from their newest observation and
  # activity from its newest entry. `nil` means the section has no dated data.
  defp freshness(now, worktrees, deploy, activity) do
    %{
      sessions: 0,
      worktrees: staleness_ms(now, worktrees |> Enum.map(&Map.get(&1, :observed_at)) |> newest()),
      deploy:
        staleness_ms(now, newest([Map.get(deploy, :finished_at), Map.get(deploy, :started_at)])),
      activity: staleness_ms(now, activity.recent |> Enum.map(&Map.get(&1, :at)) |> newest())
    }
  end

  defp newest(values) do
    values
    |> Enum.map(&to_datetime/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp staleness_ms(_now, nil), do: nil
  defp staleness_ms(now, %DateTime{} = at), do: max(DateTime.diff(now, at, :millisecond), 0)

  defp to_datetime(%DateTime{} = at), do: at

  defp to_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp to_datetime(_value), do: nil

  ## Sanitization

  # Second-line defense for exported free text: scrub secret-shaped keys, then
  # redact secret-shaped values in every remaining string (task summaries,
  # agent-state messages, handoffs, activity summaries).
  defp sanitize(digest) do
    digest
    |> Sanitizer.scrub()
    |> redact_text_values()
  end

  defp redact_text_values(%DateTime{} = value), do: value
  defp redact_text_values(%NaiveDateTime{} = value), do: value

  defp redact_text_values(value) when is_map(value) do
    Map.new(value, fn {key, child} -> {key, redact_text_values(child)} end)
  end

  defp redact_text_values(value) when is_list(value), do: Enum.map(value, &redact_text_values/1)
  defp redact_text_values(value) when is_binary(value), do: Sanitizer.redact_text(value)
  defp redact_text_values(value), do: value

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_value), do: nil

  defp tmux_adapter, do: Application.get_env(:dev_ide, :tmux_adapter, DevIDE.Terminals.Tmux)
end
