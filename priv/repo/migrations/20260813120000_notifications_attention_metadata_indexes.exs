defmodule Casein.Repo.Migrations.NotificationsAttentionMetadataIndexes do
  @moduledoc """
  Expression indexes for acknowledgement → notification sync (#922).

  `Casein.Attention.Acknowledgement` matches drawer rows by
  `metadata->>'attention_key'` / `origin_id` (and session_id fallback) on every
  terminal-window SEEN. Without these indexes Postgres must scan the user's
  full notifications table; do not drop them while that hot path exists.
  """
  use Ecto.Migration

  def change do
    # SQLite desktop path has no jsonb `->>` expression indexes; queries still
    # filter in SQL via json_extract (see acknowledgement.ex).
    unless Casein.Repo.Adapter.sqlite?(repo()) do
      create index(:notifications, ["(metadata->>'attention_key')"],
               name: :notifications_metadata_attention_key_idx
             )

      create index(:notifications, ["(metadata->>'origin_id')"],
               name: :notifications_metadata_origin_id_idx
             )

      create index(:notifications, [:user_id, :session_id],
               name: :notifications_user_id_session_id_idx
             )
    end
  end
end
