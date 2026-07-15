defmodule DevIDE.Repo.Migrations.DeviceLinkTokenExpiryIndex do
  use Ecto.Migration

  def up do
    create_if_not_exists index(:device_link_tokens, [:expires_at])
    backfill_active_token_expiry()
  end

  def down do
    drop_if_exists index(:device_link_tokens, [:expires_at])
  end

  defp backfill_active_token_expiry do
    case repo().__adapter__ do
      Ecto.Adapters.Postgres ->
        execute("""
        UPDATE device_link_tokens
        SET expires_at = GREATEST(inserted_at + interval '90 days', now() + interval '30 days')
        WHERE expires_at IS NULL AND revoked_at IS NULL
        """)

      Ecto.Adapters.SQLite3 ->
        execute("""
        UPDATE device_link_tokens
        SET expires_at = max(datetime(inserted_at, '+90 days'), datetime('now', '+30 days'))
        WHERE expires_at IS NULL AND revoked_at IS NULL
        """)
    end
  end
end
