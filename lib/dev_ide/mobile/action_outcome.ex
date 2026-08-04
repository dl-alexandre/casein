defmodule DevIDE.Mobile.ActionOutcome do
  @moduledoc """
  Durable record of a mobile card action, used as the idempotency anchor.

  Cards themselves stay transient in `DevIDE.Mobile.UserObserver`, but every
  accepted or rejected action is persisted here so that:

    * a retried submission (same `request_id`) replays the recorded outcome
      instead of re-applying the side effect, and
    * a second device racing on the same card cannot both mutate the run
      (enforced by a partial unique index on `card_id` where status = "accepted").

  See `DevIDE.Mobile.Actions` for the dispatch flow that writes these rows.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  # "accepted" — a mutating action was applied (locks the card via the partial
  #   unique index). "navigated" — a route-only action recorded for audit (no
  #   lock, so it can recur). "rejected" — validation/authorization failure.
  # "instructed" is a *successful* outcome that mutated no run: the action
  # pasted a server-authored prompt into an agent pane. It participates in the
  # (user, request_id) dedupe index like any success, but deliberately not in
  # the accepted-per-card guard — asking an agent to look at a failure again is
  # not a run resolution.
  @statuses ~w(accepted navigated instructed rejected)

  schema "mobile_action_outcomes" do
    field :request_id, :string
    field :user_id, :string
    field :card_id, :string
    field :action_id, :string
    field :resource_type, :string
    field :resource_id, :string
    field :device_link_id, :string
    field :platform, :string
    field :status, :string
    field :reason, :string
    field :result, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(outcome, attrs) do
    outcome
    |> cast(attrs, [
      :request_id,
      :user_id,
      :card_id,
      :action_id,
      :resource_type,
      :resource_id,
      :device_link_id,
      :platform,
      :status,
      :reason,
      :result
    ])
    |> validate_required([:request_id, :user_id, :card_id, :action_id, :status])
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:request_id, max: 240)
    |> validate_length(:card_id, max: 240)
    |> validate_length(:action_id, max: 80)
    |> unique_constraint(:request_id, name: :mobile_action_outcomes_user_request_active_index)
    |> unique_constraint(:card_id, name: :mobile_action_outcomes_accepted_card_id_index)
  end
end
