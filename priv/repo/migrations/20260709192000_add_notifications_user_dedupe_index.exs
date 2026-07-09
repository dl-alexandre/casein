defmodule DevIde.Repo.Migrations.AddNotificationsUserDedupeIndex do
  use Ecto.Migration

  def change do
    create index(:notifications, [:user_id, :dedupe_key, "inserted_at desc"])
  end
end
