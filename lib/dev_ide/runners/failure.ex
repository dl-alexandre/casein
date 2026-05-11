defmodule DevIDE.Runners.Failure do
  @moduledoc """
  Normalized failure classes for runner protocol v1.

  These classes are part of the JX <-> DevIDE contract. They describe why a
  protocol operation failed without expanding what runners are allowed to do.
  """

  @classes ~w(
    enqueue_failed
    claim_rejected
    lease_expired
    report_rejected
    action_failed
    replay_mismatch
    runner_lost
  )

  def classes, do: @classes

  def class(:safe_action_not_allowed), do: "enqueue_failed"
  def class(:not_found), do: "enqueue_failed"
  def class({:policy_denied, _}), do: "enqueue_failed"
  def class(:unsafe_db), do: "enqueue_failed"
  def class(:shared_stage_guarded), do: "enqueue_failed"

  def class(:capabilities_required), do: "claim_rejected"
  def class(:protocol_not_supported), do: "claim_rejected"
  def class(:runner_id_required), do: "claim_rejected"

  def class(:lease_expired), do: "lease_expired"
  def class(:runner_lost), do: "runner_lost"

  def class(:action_failed), do: "action_failed"
  def class(:replay_mismatch), do: "replay_mismatch"

  def class(:claim_token_invalid), do: "report_rejected"
  def class(:assignment_not_claimed), do: "report_rejected"
  def class(:assignment_terminal), do: "report_rejected"
  def class(:duplicate_report_conflict), do: "report_rejected"
  def class(:invalid_transition), do: "report_rejected"
  def class(:forbidden_payload), do: "report_rejected"
  def class(:event_not_allowed), do: "report_rejected"
  def class(:evidence_required), do: "report_rejected"
  def class(reason) when is_atom(reason), do: "report_rejected"
  def class({_reason, _detail}), do: "report_rejected"
  def class(_reason), do: "report_rejected"

  def terminal_class("failed"), do: "action_failed"
  def terminal_class(_status), do: nil
end
