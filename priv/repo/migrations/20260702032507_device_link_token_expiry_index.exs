defmodule DevIde.Repo.Migrations.DeviceLinkTokenExpiryIndex do
  use Ecto.Migration

  def change do
    create index(:device_link_tokens, [:expires_at])

    execute(
      """
      UPDATE device_link_tokens
      SET expires_at = GREATEST(inserted_at + interval '90 days', now() + interval '30 days')
      WHERE expires_at IS NULL AND revoked_at IS NULL
      """,
      ""
    )
  end
end
