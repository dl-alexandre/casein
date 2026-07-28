defmodule Casein.Mobile.AttentionTransition do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  schema "mobile_attention_transitions" do
    field :event_id, :string
    field :user_id, :string
    field :origin_id, :string
    field :card_id, :string
    field :workspace_id, :string
    field :session_id, :string
    field :state, :string
    field :phase, :string
    field :reason_code, :string
    field :event_action, :string
    field :occurred_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(transition, attrs) do
    transition
    |> cast(attrs, [
      :event_id,
      :user_id,
      :origin_id,
      :card_id,
      :workspace_id,
      :session_id,
      :state,
      :phase,
      :reason_code,
      :event_action,
      :occurred_at
    ])
    |> validate_required([
      :user_id,
      :origin_id,
      :card_id,
      :workspace_id,
      :state,
      :phase,
      :reason_code,
      :event_action,
      :occurred_at
    ])
    |> validate_length(:event_id, max: 240)
    |> validate_length(:origin_id, max: 240)
    |> validate_length(:card_id, max: 240)
    |> validate_length(:workspace_id, max: 240)
    |> validate_length(:session_id, max: 240)
    |> validate_length(:state, max: 40)
    |> validate_length(:phase, max: 40)
    |> validate_length(:reason_code, max: 80)
    |> validate_length(:event_action, max: 120)
    |> unique_constraint(:event_id, name: :mobile_attention_transitions_event_index)
  end
end
