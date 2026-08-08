defmodule Casein.Mobile.AttentionCursor do
  @moduledoc """
  Durable per-viewer acknowledgement row (SEEN + optional RESOLVED).

  Table name remains `mobile_attention_cursors` for migration continuity.
  Cross-surface API lives in `Casein.Attention.Acknowledgement`. The `card_id`
  column holds the subject id for every `subject_kind` (`card`,
  `session_window`, `notification`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @subject_kinds ~w(card session_window notification)

  schema "mobile_attention_cursors" do
    field :user_id, :string
    field :origin_id, :string
    field :subject_kind, :string, default: "card"
    # subject id (card attention key, session window key, or notification id)
    field :card_id, :string
    field :through_transition_id, :integer
    field :viewed_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [
      :user_id,
      :origin_id,
      :subject_kind,
      :card_id,
      :through_transition_id,
      :viewed_at,
      :resolved_at
    ])
    |> validate_required([
      :user_id,
      :origin_id,
      :subject_kind,
      :card_id,
      :through_transition_id,
      :viewed_at
    ])
    |> validate_inclusion(:subject_kind, @subject_kinds)
    |> validate_number(:through_transition_id, greater_than: 0)
    |> validate_length(:origin_id, max: 240)
    |> validate_length(:card_id, max: 240)
    |> unique_constraint([:user_id, :origin_id, :subject_kind, :card_id],
      name: :mobile_attention_cursors_scope_index
    )
  end
end
