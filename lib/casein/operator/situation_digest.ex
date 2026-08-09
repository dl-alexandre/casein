defmodule Casein.Operator.SituationDigest do
  @moduledoc """
  Cold operator situation digest for a single workspace.

  This is a composition layer, not a new source of truth: every section is
  read from an existing read model — `Casein.Workspaces.SessionSummary` for
  sessions and agent layout, `Casein.Terminals.AgentState` for semantic pane
  states, `Casein.Runtimes.list_agent_worktrees/1` for agent worktrees,
  `Casein.Deployment.Health` for deploy status, `Casein.Agents.Activity` and
  `Casein.Audit` for recent activity. Nothing is re-derived here. The one
  filesystem read is `frozen_scopes`: freeze-skill sentinel files observed
  under the workspace and worktree roots (facts only, no enforcement).

  The digest is a summary payload: free text (task summaries, agent-state
  messages, handoffs, activity summaries) is redacted through
  `Casein.Export.Sanitizer`, and no raw terminal scrollback is ever included.
  `risks` is filled by `Casein.Operator.Risks.detect/1` over the finished
  digest.
  """

  alias Casein.Agents.Activity
  alias Casein.Audit
  alias Casein.Deployment.Health
  alias Casein.Export.Sanitizer
  alias Casein.Operator.Risks
  alias Casein.Ops.PgProbe
  alias Casein.Runtimes
  alias Casein.Labels
  alias Casein.Terminals.AgentState
  alias Casein.Terminals.FleetChrome
  alias Casein.Terminals.IssueBinding
  alias Casein.Terminals.TmuxTopology
  alias Casein.Workspaces
  alias Casein.Workspaces.SessionSummary

  @recent_activity 20
  @recent_audit 20

  @deploy_fallback %{
    running_revision: nil,
    drift: nil,
    pipeline: :unknown,
    phase: nil,
    actionable: false
  }

  @doc """
  Build the situation digest for `workspace_id`.

  Sections degrade independently: a failing constituent read (dead tmux,
  missing workspace record, unreachable deploy poller file) empties its own
  section instead of failing the digest. Every section that degraded this way
  is listed in the digest's `degraded` key, so consumers — notably the
  `Casein.Operator.SituationServer` risk differ — can tell "actually empty"
  from "unreadable right now" and avoid treating missing data as recovery.
  """
  @spec build(String.t()) :: {:ok, map()} | {:error, term()}
  def build(workspace_id) when is_binary(workspace_id) and workspace_id != "" do
    now = DateTime.utc_now()
    {summary, summary_ok?} = guarded(fn -> session_summary(workspace_id) end, %{sessions: []})
    {sessions, panes_ok?} = session_digests(summary, now)
    {worktrees, worktrees_ok?} = guarded(fn -> worktrees(workspace_id) end, [])

    {frozen_scopes, frozen_ok?} =
      guarded(fn -> frozen_scopes(workspace_id, worktrees) end, [])

    {deploy, deploy_ok?} = guarded(fn -> deploy() end, @deploy_fallback)
    {recent, recent_ok?} = guarded(fn -> recent_activity(workspace_id) end, [])
    {last_mutation, last_mutation_ok?} = guarded(fn -> last_mutation(workspace_id) end, nil)
    activity = %{recent: recent, last_mutation: last_mutation}

    degraded =
      for {section, ok?} <- [
            sessions: summary_ok? and panes_ok?,
            worktrees: worktrees_ok?,
            frozen_scopes: frozen_ok?,
            deploy: deploy_ok?,
            activity: recent_ok? and last_mutation_ok?
          ],
          not ok?,
          do: section

    digest =
      %{
        workspace_id: workspace_id,
        generated_at: now,
        freshness: freshness(now, worktrees, deploy, activity),
        sessions: sessions,
        agent_layout: agent_layout(summary),
        worktrees: worktrees,
        frozen_scopes: frozen_scopes,
        deploy: deploy,
        activity: activity,
        degraded: degraded,
        risks: []
      }
      |> put_ops()
      |> sanitize()

    {:ok, %{digest | risks: Risks.detect(digest)}}
  end

  def build(_workspace_id), do: {:error, :invalid_workspace_id}

  # Rescue-to-fallback for one section read: the digest keeps building, the
  # section empties, and the degradation is reported instead of swallowed.
  defp guarded(fun, fallback) do
    {fun.(), true}
  rescue
    _ -> {fallback, false}
  catch
    :exit, _ -> {fallback, false}
  end

  ## Sessions

  defp session_summary(workspace_id) do
    ws =
      case Workspaces.get_record(workspace_id) do
        {:ok, record} -> record
        :error -> %{id: workspace_id, name: workspace_id}
      end

    SessionSummary.build(ws)
  end

  # Pane reads degrade per session (one dead tmux session must not empty the
  # others), so degradation bubbles up as a flag instead of a rescue.
  defp session_digests(summary, now) do
    Enum.map_reduce(Map.get(summary, :sessions, []), true, fn session, ok? ->
      {digest, session_ok?} = session_digest(session, now)
      {digest, ok? and session_ok?}
    end)
  end

  defp session_digest(session, now) do
    tmux_session = present(Map.get(session, :tmux_session))
    {panes, ok?} = panes(tmux_session, now)

    digest =
      %{
        sid: Map.get(session, :id),
        tmux_session: tmux_session,
        agent_status: Map.get(session, :agent_status),
        panes: panes
      }
      |> compact()

    {digest, ok?}
  end

  defp panes(nil, _now), do: {[], true}

  defp panes(tmux_session, now) do
    reports = AgentState.for_session(tmux_session)

    topology =
      tmux_session
      |> TmuxTopology.snapshot(tmux: tmux_adapter())
      |> AgentState.enrich_topology(tmux_session)
      |> IssueBinding.enrich_topology(tmux_session)
      |> Labels.enrich_topology(tmux_session)
      |> put_report_ages(reports, now)
      |> put_window_names_on_panes()
      |> FleetChrome.enrich_topology()

    {Enum.map(topology.panes, &pane_digest(&1, reports, now)), true}
  rescue
    _ -> {[], false}
  catch
    :exit, _ -> {[], false}
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
      current_path: Map.get(pane, :current_path),
      label: Map.get(pane, :label),
      issue: Map.get(pane, :issue),
      fleet_role: Map.get(pane, :fleet_role),
      fleet_readiness: Map.get(pane, :fleet_readiness),
      ready_no_task_for_seconds: Map.get(pane, :ready_no_task_for_seconds)
    }
    |> compact()
  end

  # FleetChrome prefers liveness quiet_for_seconds; without a worktree walk the
  # digest still surfaces ready_no_task from the explicit report age.
  defp put_report_ages(%{panes: panes} = topology, reports, now) when is_list(panes) do
    %{
      topology
      | panes:
          Enum.map(panes, fn pane ->
            case report_age_s(pane, reports, now) do
              age when is_integer(age) -> Map.put(pane, :agent_state_age_s, age)
              _ -> pane
            end
          end)
    }
  end

  defp put_report_ages(topology, _reports, _now), do: topology

  defp put_window_names_on_panes(%{panes: panes, windows: windows} = topology)
       when is_list(panes) and is_list(windows) do
    names =
      for window <- windows,
          id = Map.get(window, :id) || Map.get(window, "id"),
          is_binary(id),
          name = Map.get(window, :name) || Map.get(window, "name"),
          is_binary(name) and name != "",
          into: %{},
          do: {id, name}

    if map_size(names) == 0 do
      topology
    else
      %{
        topology
        | panes:
            Enum.map(panes, fn pane ->
              window_id = Map.get(pane, :window_id) || Map.get(pane, "window_id")

              case Map.get(names, window_id) do
                name when is_binary(name) -> Map.put(pane, :window_name, name)
                _ -> pane
              end
            end)
      }
    end
  end

  defp put_window_names_on_panes(topology), do: topology

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
        upstream: Map.get(worktree, :upstream),
        ahead: Map.get(worktree, :ahead),
        behind: Map.get(worktree, :behind),
        dirty_count: Map.get(worktree, :dirty_count),
        status: Map.get(worktree, :worktree_status),
        exit_status: Map.get(worktree, :exit_status),
        handoff: Map.get(worktree, :handoff),
        observed_at: Map.get(worktree, :observed_at)
      }
      |> compact()
    end)
  end

  ## Frozen scopes

  # The elixir-phoenix freeze skill locks agent edits behind a sentinel file
  # (`.claude/.freeze` under the checkout root) enforced by a PreToolUse hook.
  # The app has no model of that lock — this section only observes matching
  # sentinel files under the workspace root and every agent worktree root so
  # the digest can report a frozen scope as fact. Nothing here enforces or
  # toggles the lock. Sentinel locations are configurable via
  # `:freeze_sentinel_globs` (globs relative to each scanned root), read at
  # digest build time.
  @default_freeze_sentinel_globs [".claude/.freeze"]
  @freeze_raw_max_chars 400

  defp frozen_scopes(workspace_id, worktrees) do
    roots =
      [workspace_root(workspace_id) | Enum.map(worktrees, &Map.get(&1, :path))]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq()

    for root <- roots,
        glob <- freeze_sentinel_globs(),
        sentinel <- Path.wildcard(Path.join(root, glob), match_dot: true),
        File.regular?(sentinel) do
      %{path: root, sentinel: sentinel, raw: sentinel_raw(sentinel)}
      |> compact()
    end
  end

  defp workspace_root(workspace_id) do
    case Workspaces.get_record(workspace_id) do
      {:ok, record} -> Map.get(record, :host_path)
      :error -> nil
    end
  end

  defp freeze_sentinel_globs do
    case Application.get_env(:casein, :freeze_sentinel_globs, @default_freeze_sentinel_globs) do
      globs when is_list(globs) -> Enum.filter(globs, &is_binary/1)
      _ -> @default_freeze_sentinel_globs
    end
  end

  # An empty sentinel means "freeze everything" — the compacted scope simply
  # carries no :raw key. Content is truncated here and redacted with the rest
  # of the digest's free text by sanitize/1.
  #
  # Sentinel paths come from operator config globs expanded under workspace /
  # worktree roots, never from caller input.
  # sobelow_skip ["Traversal.FileModule"]
  defp sentinel_raw(sentinel) do
    with {:ok, raw} <- File.read(sentinel),
         true <- String.valid?(raw) do
      truncate(String.trim(raw))
    else
      _ -> nil
    end
  end

  defp truncate(raw) do
    if String.length(raw) > @freeze_raw_max_chars do
      String.slice(raw, 0, @freeze_raw_max_chars) <> "…"
    else
      raw
    end
  end

  ## Deploy

  @doc """
  The digest's deploy section on its own — used by
  `Casein.Operator.SituationServer` to refresh just this section on
  `"deploy:updates"` events without a full rebuild.
  """
  @spec deploy_section() :: map()
  def deploy_section do
    {deploy, _ok?} = guarded(fn -> deploy() end, @deploy_fallback)
    deploy
  end

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

  ## Ops

  # Box-level infrastructure health rides along only while its producer runs:
  # with a live Casein.Ops.PgProbe the digest gains ops.pg (the latest
  # per-target saturation samples); without one the key is absent entirely so
  # consumers can tell "healthy" from "not measured".
  defp put_ops(digest) do
    if PgProbe.running?() do
      Map.put(digest, :ops, %{pg: PgProbe.current()})
    else
      digest
    end
  end

  ## Activity

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
  end

  ## Freshness

  @doc """
  Absolute per-section reference instants behind `freshness`: `generated_at`
  minus each section's staleness (`nil` where the section has no dated data).

  `Casein.Operator.SituationServer` keeps these and re-stamps `freshness`
  with `freshness_from/2` at read time, so live-served digests age instead of
  carrying stamps frozen at the last full rebuild.
  """
  @spec freshness_as_of(map()) :: %{atom() => DateTime.t() | nil}
  def freshness_as_of(%{generated_at: %DateTime{} = at, freshness: freshness}) do
    Map.new(freshness, fn
      {section, ms} when is_integer(ms) -> {section, DateTime.add(at, -ms, :millisecond)}
      {section, _undated} -> {section, nil}
    end)
  end

  @doc "Re-stamp `freshness` as millisecond staleness against `now`."
  @spec freshness_from(%{atom() => DateTime.t() | nil}, DateTime.t()) :: map()
  def freshness_from(as_of, %DateTime{} = now) when is_map(as_of) do
    Map.new(as_of, fn {section, at} -> {section, staleness_ms(now, at)} end)
  end

  @doc "The newest dated instant in a deploy section (`nil` when undated)."
  @spec deploy_as_of(map()) :: DateTime.t() | nil
  def deploy_as_of(deploy) when is_map(deploy) do
    newest([Map.get(deploy, :finished_at), Map.get(deploy, :started_at)])
  end

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

  defp tmux_adapter, do: Application.get_env(:casein, :tmux_adapter, Casein.Terminals.Tmux)
end
