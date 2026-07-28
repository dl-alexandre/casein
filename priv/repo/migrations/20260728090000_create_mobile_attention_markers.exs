defmodule Casein.Repo.Migrations.CreateMobileAttentionMarkers do
  use Ecto.Migration

  def up do
    create table(:mobile_attention_transitions, primary_key: false) do
      add :id, :bigserial, primary_key: true
      add :event_id, :text
      add :user_id, :text, null: false
      add :origin_id, :text, null: false
      add :card_id, :text, null: false
      add :workspace_id, :text, null: false
      add :session_id, :text
      add :state, :text, null: false
      add :phase, :text, null: false
      add :reason_code, :text, null: false
      add :event_action, :text, null: false
      add :occurred_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:mobile_attention_transitions, [:user_id, :origin_id, :card_id, :id],
             name: :mobile_attention_transitions_card_marker_index
           )

    create index(:mobile_attention_transitions, [:user_id, :origin_id, :id],
             name: :mobile_attention_transitions_origin_marker_index
           )

    create unique_index(:mobile_attention_transitions, [:user_id, :origin_id, :event_id],
             where: "event_id IS NOT NULL",
             name: :mobile_attention_transitions_event_index
           )

    create table(:mobile_attention_cursors, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, :text, null: false
      add :origin_id, :text, null: false
      add :card_id, :text, null: false
      add :through_transition_id, :bigint, null: false
      add :viewed_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mobile_attention_cursors, [:user_id, :origin_id, :card_id],
             name: :mobile_attention_cursors_scope_index
           )
  end

  def down do
    drop table(:mobile_attention_cursors)
    drop table(:mobile_attention_transitions)
  end
end
