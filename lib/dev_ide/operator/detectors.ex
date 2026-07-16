defmodule DevIDE.Operator.Detectors do
  @moduledoc """
  Pure rules for the *stateful* operator risks.

  `DevIDE.Operator.Risks.detect/1` covers everything a single digest can
  prove; these rules additionally need observations a live
  `DevIDE.Operator.SituationServer` accumulates over time (agent-state
  reports with their `reported_at`, per-session output freshness, cached
  worktree-alarm sweeps). Every function takes that observation state
  explicitly — no live reads — so the same inputs always yield the same
  risks and each rule is unit-testable with fabricated state.

  Risks share the `DevIDE.Operator.Risks.risk/0` shape so consumers see one
  uniform list.
  """

  alias DevIDE.Export.Sanitizer

  @doc """
  Agent panes reporting `:blocked` for longer than `threshold_s`.

  `entries` is the server's `%{{tmux_session, pane_id} => AgentState.entry()}`
  observation map. A short block is normal (the plain `:agent_blocked` risk
  already flags it); one older than the threshold means nobody is answering
  the prompt.
  """
  @spec blocked_too_long(map(), DateTime.t(), pos_integer()) :: [map()]
  def blocked_too_long(entries, %DateTime{} = now, threshold_s) when is_map(entries) do
    for {{tmux_session, pane_id}, entry} <- entries,
        Map.get(entry, :state) == :blocked,
        %DateTime{} = reported_at <- [Map.get(entry, :reported_at)],
        blocked_s = DateTime.diff(now, reported_at, :second),
        blocked_s >= threshold_s do
      risk(
        :blocked_too_long,
        :critical,
        subject(tmux_session, pane_id),
        now,
        %{
          blocked_for_s: blocked_s,
          threshold_s: threshold_s,
          message: sanitize(Map.get(entry, :message))
        },
        "An agent pane has been :blocked for over #{div(threshold_s, 60)} min with no " <>
          "answer. Inspect it with terminal_capture_agent and respond to the prompt."
      )
    end
  end

  @doc """
  Panes reporting `:working` whose *session* produced no terminal output for
  longer than `threshold_s`.

  `last_output_at` is the server's `%{sid => DateTime}` map — seeded at
  subscribe time and bumped on every `SessionEvents` output event, so "no
  entry" means the session was never observed and cannot be judged.
  """
  @spec working_no_output(map() | nil, map(), DateTime.t(), pos_integer()) :: [map()]
  def working_no_output(digest, last_output_at, %DateTime{} = now, threshold_s)
      when is_map(last_output_at) do
    for session <- sessions(digest),
        sid = Map.get(session, :sid),
        %DateTime{} = output_at <- [Map.get(last_output_at, sid)],
        silent_s = DateTime.diff(now, output_at, :second),
        silent_s >= threshold_s,
        pane <- Map.get(session, :panes) || [],
        Map.get(pane, :agent_state) == :working do
      risk(
        :working_no_output,
        :warn,
        subject(Map.get(session, :tmux_session) || sid, Map.get(pane, :id)),
        now,
        %{
          sid: sid,
          silent_for_s: silent_s,
          threshold_s: threshold_s,
          task_summary: Map.get(pane, :task_summary)
        },
        "A pane reports :working but its session produced no output for over " <>
          "#{div(threshold_s, 60)} min — the agent may be hung. Inspect it with " <>
          "terminal_capture_agent."
      )
    end
  end

  @doc """
  Stale agent worktrees from a cached `DevIDE.Runtimes.WorktreeAlarm` sweep.

  `alarms` is the alarm list of the latest sweep (the server refreshes it at
  most once per minute); only alarms attributed to `workspace_id` surface
  here so subjects stay workspace-scoped.
  """
  @spec leaked_worktree([map()], String.t(), DateTime.t()) :: [map()]
  def leaked_worktree(alarms, workspace_id, %DateTime{} = now) when is_list(alarms) do
    for alarm <- alarms, Map.get(alarm, :workspace_id) == workspace_id do
      risk(
        :leaked_worktree,
        :warn,
        Map.get(alarm, :path),
        now,
        %{
          branch: Map.get(alarm, :branch),
          dirty: Map.get(alarm, :dirty),
          age_seconds: Map.get(alarm, :age_seconds),
          reasons: Map.get(alarm, :reasons)
        },
        "A stale agent worktree has no live process and no exit handoff. Land or " <>
          "report it (terminal_report_worktree), or remove it if abandoned."
      )
    end
  end

  defp risk(id, severity, subject, detected_at, evidence, suggestion) do
    %{
      id: id,
      severity: severity,
      subject: subject,
      detected_at: detected_at,
      evidence: compact(evidence),
      suggestion: suggestion
    }
  end

  defp subject(session, pane_id) do
    [session, pane_id]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp sessions(digest) when is_map(digest), do: Map.get(digest, :sessions) || []
  defp sessions(_digest), do: []

  # Detector evidence can land in audit rows and exported payloads; free text
  # goes through the same redaction as the digest itself.
  defp sanitize(text) when is_binary(text), do: Sanitizer.redact_text(text)
  defp sanitize(_text), do: nil

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
