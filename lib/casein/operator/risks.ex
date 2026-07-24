defmodule Casein.Operator.Risks do
  @moduledoc """
  Pure risk rules over a `Casein.Operator.SituationDigest` map.

  `detect/1` never reads live state: every rule pattern-matches fields the
  digest already carries, so the same digest always yields the same risks.
  `detected_at` is the digest's `generated_at` for the same reason.
  """

  @type severity :: :info | :warn | :critical

  @type risk :: %{
          id: atom(),
          severity: severity(),
          subject: String.t() | nil,
          detected_at: DateTime.t() | nil,
          evidence: map(),
          suggestion: String.t()
        }

  @doc "Detect all known risks in a situation digest."
  @spec detect(map()) :: [risk()]
  def detect(digest) when is_map(digest) do
    dirty_no_handoff(digest) ++
      unpushed_work(digest) ++
      deploy_drift(digest) ++
      deploy_gate_failed(digest) ++
      agent_blocked(digest) ++
      missing_agent_pane(digest) ++
      frozen_scope_active(digest)
  end

  # Dirty worktree whose session did not land and left no handoff: work is at
  # risk of being lost or silently duplicated by the next agent.
  defp dirty_no_handoff(digest) do
    for worktree <- worktrees(digest),
        dirty?(worktree),
        Map.get(worktree, :exit_status) != "landed",
        blank?(Map.get(worktree, :handoff)) do
      risk(
        digest,
        :dirty_no_handoff,
        :warn,
        Map.get(worktree, :path),
        %{
          branch: Map.get(worktree, :branch),
          dirty_count: Map.get(worktree, :dirty_count),
          exit_status: Map.get(worktree, :exit_status)
        },
        "Land the changes, or report exit_status/handoff via terminal_report_worktree " <>
          "so the worktree is a deliberate handoff instead of an orphan."
      )
    end
  end

  # Commits that exist only in a worktree whose agent looks gone or idle.
  # "Gone/idle" is a documented heuristic, not ground truth — the digest
  # carries no liveness signal for the agent that owns a worktree, so we treat
  # either of these as the agent no longer driving it:
  #   * a reported exit_status (the agent told us it stopped, whatever the
  #     status — even "landed" work with ahead > 0 has commits the landing
  #     did not carry upstream), or
  #   * an observation older than @unpushed_idle_after_s (nothing has
  #     re-observed the worktree recently, so no agent is active in it).
  # Worktrees without upstream tracking (ahead: nil) never fire.
  @unpushed_idle_after_s 15 * 60

  defp unpushed_work(digest) do
    for worktree <- worktrees(digest),
        ahead = Map.get(worktree, :ahead),
        is_integer(ahead) and ahead > 0,
        agent_gone_or_idle?(worktree, Map.get(digest, :generated_at)) do
      risk(
        digest,
        :unpushed_work,
        :warn,
        Map.get(worktree, :path),
        %{
          branch: Map.get(worktree, :branch),
          upstream: Map.get(worktree, :upstream),
          ahead: ahead,
          exit_status: Map.get(worktree, :exit_status),
          observed_at: Map.get(worktree, :observed_at)
        },
        "The worktree has #{ahead} commit(s) its upstream never received and no " <>
          "agent appears to be driving it. Push the branch or hand the work off " <>
          "before the worktree is cleaned up."
      )
    end
  end

  defp agent_gone_or_idle?(worktree, generated_at) do
    not blank?(Map.get(worktree, :exit_status)) or
      stale_observation?(Map.get(worktree, :observed_at), generated_at)
  end

  defp stale_observation?(observed_at, %DateTime{} = generated_at)
       when is_binary(observed_at) do
    case DateTime.from_iso8601(observed_at) do
      {:ok, at, _offset} -> stale_observation?(at, generated_at)
      _ -> false
    end
  end

  defp stale_observation?(%DateTime{} = observed_at, %DateTime{} = generated_at) do
    DateTime.diff(generated_at, observed_at, :second) >= @unpushed_idle_after_s
  end

  defp stale_observation?(_observed_at, _generated_at), do: false

  defp deploy_drift(digest) do
    deploy = deploy(digest)

    if Map.get(deploy, :drift) == true do
      [
        risk(
          digest,
          :deploy_drift,
          :warn,
          Map.get(deploy, :running_revision),
          %{pipeline: Map.get(deploy, :pipeline), phase: Map.get(deploy, :phase)},
          "The running revision is behind the remote deploy branch. Deploy the " <>
            "latest revision or confirm the pin is intentional."
        )
      ]
    else
      []
    end
  end

  defp deploy_gate_failed(digest) do
    deploy = deploy(digest)

    if Map.get(deploy, :pipeline) == :failed and Map.get(deploy, :phase) == "gate" do
      [
        risk(
          digest,
          :deploy_gate_failed,
          :critical,
          Map.get(deploy, :running_revision),
          %{pipeline: :failed, phase: "gate"},
          "The deploy pipeline failed at the gate phase. Inspect the gate failure " <>
            "before retrying — pushes will keep failing until it is fixed."
        )
      ]
    else
      []
    end
  end

  # Any pane with a live :blocked report is an agent waiting on a human.
  defp agent_blocked(digest) do
    for session <- sessions(digest),
        pane <- Map.get(session, :panes) || [],
        Map.get(pane, :agent_state) == :blocked do
      risk(
        digest,
        :agent_blocked,
        :warn,
        blocked_subject(session, pane),
        %{
          agent_state_age_s: Map.get(pane, :agent_state_age_s),
          task_summary: Map.get(pane, :task_summary)
        },
        "An agent pane reports :blocked and is waiting for input. Inspect it with " <>
          "terminal_capture_agent and answer the pending prompt."
      )
    end
  end

  defp missing_agent_pane(digest) do
    case get_in(digest, [:agent_layout, :status]) do
      "missing_agent_pane" ->
        [
          risk(
            digest,
            :missing_agent_pane,
            :info,
            Map.get(digest, :workspace_id),
            %{layout_status: "missing_agent_pane"},
            "No session has a role-marked agent pane; agent-pane tools will fail. " <>
              "Apply the agent_pair template."
          )
        ]

      _ ->
        []
    end
  end

  # One :info entry per observed freeze sentinel — the digest reports the lock
  # as a fact so an operator is not surprised by denied agent edits. Purely
  # observational: nothing here (or anywhere in the app) enforces the freeze.
  defp frozen_scope_active(digest) do
    for scope <- Map.get(digest, :frozen_scopes) || [] do
      risk(
        digest,
        :frozen_scope_active,
        :info,
        Map.get(scope, :path),
        %{sentinel: Map.get(scope, :sentinel), raw: Map.get(scope, :raw)},
        "An edit-freeze sentinel is active in this scope, so agent edits outside " <>
          "its allow-list are denied. Lift it with /phx:freeze off once the " <>
          "focused task is done."
      )
    end
  end

  defp risk(digest, id, severity, subject, evidence, suggestion) do
    %{
      id: id,
      severity: severity,
      subject: subject,
      detected_at: Map.get(digest, :generated_at),
      evidence: compact(evidence),
      suggestion: suggestion
    }
  end

  defp blocked_subject(session, pane) do
    [Map.get(session, :tmux_session) || Map.get(session, :sid), Map.get(pane, :id)]
    |> Enum.reject(&blank?/1)
    |> Enum.join(" ")
  end

  defp dirty?(worktree) do
    Map.get(worktree, :status) == "dirty" or
      (is_integer(Map.get(worktree, :dirty_count)) and Map.get(worktree, :dirty_count) > 0)
  end

  defp sessions(digest), do: Map.get(digest, :sessions) || []
  defp worktrees(digest), do: Map.get(digest, :worktrees) || []
  defp deploy(digest), do: Map.get(digest, :deploy) || %{}

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end
end
