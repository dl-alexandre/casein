defmodule Casein.Repo.Migrations.AddUserToWorkspaceRecords do
  use Ecto.Migration

  # `Casein.Workspaces.Reconciler` may only retire records for users the
  # authoritative manager listing actually covered (the manager filters
  # `GET /api/workspaces` to the caller's own user unless it is an admin
  # asking for `?all=true`). That per-user scoping needs the owner on the
  # record. Backfills itself on the next source sync; records left NULL are
  # simply never eligible for reconciliation.
  def change do
    alter table(:workspace_records) do
      add :user, :text
    end

    create index(:workspace_records, [:user])
  end
end
