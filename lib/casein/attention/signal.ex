defmodule Casein.Attention.Signal do
  @moduledoc """
  Domain attention signals — *what happened*, not UI section or reaction.

  Signals feed `Casein.Attention.Salience`. Surfaces must not invent parallel
  signal enums; they project from salience.

  ## Vocabulary (post-#696 / H28)

  - `:idle` — agent window went quiet, therefore the operator is needed.
    Raised from the directory window `:quiet` flag. This is **not** "suppress
    this notification" (that is delivery / `Casein.Attention.Policy`).
  - `:agent_blocked` — agent reported it needs a human (report-only).
  - `:agent_errored` — agent **reported** failure (`:errored`). Report-only;
    never derived from liveness.
  - `:agent_stalled` — pane looks busy and external liveness is quiet
    (derived-only). Never reported by an agent; never collapsed into blocked.
  - Other atoms name lifecycle/domain facts (`:run_failed`, …).

  ## Kind discipline (from `Casein.Terminals.AgentState`)

  Report-only and derived-only states must stay distinct through salience.
  Collapsing `:stalled` or `:errored` into `:agent_blocked` loses that kind
  boundary and makes cockpit chrome invent a second classifier.
  """

  @type t ::
          :agent_blocked
          | :agent_errored
          | :agent_stalled
          | :approval_pending
          | :deploy_failed
          | :run_failed
          | :checks_failed
          | :apply_failed
          | :deploy_succeeded
          | :run_completed
          | :idle
          | :working
          | :offline_resumable
          | :informational

  @meaningful_actions ~w(
    run.started run.approval_requested run.approval_granted run.approval_denied
    run.succeeded run.failed run.timed_out
    agent.blocked agent.state_changed
    gate.passed gate.failed
    proposal.applied proposal.apply_failed
    deploy.started deploy.succeeded deploy.failed
  )

  @doc "Allowlisted audited lifecycle actions that may feed signals."
  @spec meaningful_actions() :: [String.t()]
  def meaningful_actions, do: @meaningful_actions

  @doc "True when `action` is an allowlisted lifecycle fact."
  @spec meaningful_action?(term()) :: boolean()
  def meaningful_action?(action) when is_binary(action), do: action in @meaningful_actions
  def meaningful_action?(_action), do: false

  @doc """
  Map an audited event action string to a signal, when the action alone is
  decisive. Returns `nil` when the action needs card/resume context (e.g.
  `agent.state_changed`).
  """
  @spec from_event_action(term()) :: t() | nil
  def from_event_action(action) when is_binary(action) do
    case action do
      "agent.blocked" -> :agent_blocked
      "run.approval_requested" -> :approval_pending
      "deploy.failed" -> :deploy_failed
      "run.failed" -> :run_failed
      "run.timed_out" -> :run_failed
      "gate.failed" -> :checks_failed
      "proposal.apply_failed" -> :apply_failed
      "deploy.succeeded" -> :deploy_succeeded
      "run.succeeded" -> :run_completed
      "proposal.applied" -> :run_completed
      "run.started" -> :working
      "deploy.started" -> :working
      "gate.passed" -> :working
      "run.approval_granted" -> :working
      "run.approval_denied" -> :run_completed
      _ -> nil
    end
  end

  def from_event_action(_action), do: nil
end
