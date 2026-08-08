defmodule Casein.Repo.Migrations.AttentionAcknowledgements do
  use Ecto.Migration

  @moduledoc false

  # Evolves mobile_attention_cursors into the single cross-surface acknowledgement
  # store (#698). Additive: existing SEEN watermarks stay put (no mass-unread).
  # subject_kind defaults to "card" so legacy cursor rows remain valid.
  #
  # Notification backfill runs in Elixir
  # (`Casein.Attention.Acknowledgement.backfill_from_notifications/0`) so
  # postgres/sqlite JSON access stays one path, exercised by the migration test.

  def up do
    # Columns may already exist if a partial prior run landed them without the
    # index swap — keep this idempotent.
    unless column_exists?(:mobile_attention_cursors, :subject_kind) do
      alter table(:mobile_attention_cursors) do
        add :subject_kind, :text, null: false, default: "card"
      end
    end

    unless column_exists?(:mobile_attention_cursors, :resolved_at) do
      alter table(:mobile_attention_cursors) do
        add :resolved_at, :utc_datetime_usec
      end
    end

    # Always rebuild the scope unique index to (user_id, origin_id, subject_kind, card_id).
    drop_if_exists index(:mobile_attention_cursors, [:user_id, :origin_id, :card_id],
                     name: :mobile_attention_cursors_scope_index
                   )

    drop_if_exists index(
                     :mobile_attention_cursors,
                     [:user_id, :origin_id, :subject_kind, :card_id],
                     name: :mobile_attention_cursors_scope_index
                   )

    create unique_index(
             :mobile_attention_cursors,
             [:user_id, :origin_id, :subject_kind, :card_id],
             name: :mobile_attention_cursors_scope_index
           )

    drop_if_exists index(:mobile_attention_cursors, [:user_id, :subject_kind],
                     name: :mobile_attention_cursors_user_kind_index
                   )

    create index(:mobile_attention_cursors, [:user_id, :subject_kind],
             name: :mobile_attention_cursors_user_kind_index
           )
  end

  def down do
    drop_if_exists index(:mobile_attention_cursors, [:user_id, :subject_kind],
                     name: :mobile_attention_cursors_user_kind_index
                   )

    drop_if_exists index(
                     :mobile_attention_cursors,
                     [:user_id, :origin_id, :subject_kind, :card_id],
                     name: :mobile_attention_cursors_scope_index
                   )

    execute("DELETE FROM mobile_attention_cursors WHERE subject_kind <> 'card'")

    create unique_index(:mobile_attention_cursors, [:user_id, :origin_id, :card_id],
             name: :mobile_attention_cursors_scope_index
           )

    if column_exists?(:mobile_attention_cursors, :resolved_at) do
      alter table(:mobile_attention_cursors) do
        remove :resolved_at
      end
    end

    if column_exists?(:mobile_attention_cursors, :subject_kind) do
      alter table(:mobile_attention_cursors) do
        remove :subject_kind
      end
    end
  end

  defp column_exists?(table, column) do
    repo = repo()

    %{rows: rows} =
      repo.query!("""
      SELECT 1
      FROM information_schema.columns
      WHERE table_name = '#{table}' AND column_name = '#{column}'
      LIMIT 1
      """)

    rows != []
  rescue
    _ -> false
  end
end
