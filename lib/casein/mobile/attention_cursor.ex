defmodule Casein.Mobile.AttentionCursor do
  @moduledoc false

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "mobile_attention_cursors" do
    field :user_id, :string
    field :origin_id, :string
    field :card_id, :string
    field :through_transition_id, :integer
    field :viewed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(cursor, attrs) do
    cursor
    |> cast(attrs, [:user_id, :origin_id, :card_id, :through_transition_id, :viewed_at])
    |> validate_required([
      :user_id,
      :origin_id,
      :card_id,
      :through_transition_id,
      :viewed_at
    ])
    |> validate_number(:through_transition_id, greater_than: 0)
    |> validate_length(:origin_id, max: 240)
    |> validate_length(:card_id, max: 240)
    |> unique_constraint([:user_id, :origin_id, :card_id],
      name: :mobile_attention_cursors_scope_index
    )
  end
end
