defmodule DevIDE.Operator.Risks do
  @moduledoc """
  Pure risk rules over a `DevIDE.Operator.SituationDigest` map.

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
      deploy_drift(digest) ++
      deploy_gate_failed(digest) ++
      agent_blocked(digest) ++
      missing_agent_pane(digest)
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
