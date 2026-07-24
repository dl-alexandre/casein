defmodule Casein.Repo.Migrations.AddPreviewObservationsLatestIndex do
  use Ecto.Migration

  # Serves the "latest observation per (session, kind)" queries in
  # Casein.PreviewControl (latest_errors/1) without a post-filter sort.
  # The old (session_id, kind) index is a strict prefix of this one, so it is
  # redundant once this exists.
  def change do
    create index(:preview_observations, ["session_id", "kind", "inserted_at DESC", "id DESC"],
             name: :preview_observations_session_kind_latest_idx
           )

    drop index(:preview_observations, [:session_id, :kind])
  end
end
