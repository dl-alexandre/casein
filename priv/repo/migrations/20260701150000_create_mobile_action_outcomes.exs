defmodule Casein.Repo.Migrations.CreateMobileActionOutcomes do
  use Ecto.Migration

  def change do
    create table(:mobile_action_outcomes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # Client-supplied (or server-derived) dedupe key. Retried submissions with
      # the same request_id replay the recorded outcome instead of re-applying.
      add :request_id, :text, null: false
      add :user_id, :text, null: false
      add :card_id, :text, null: false
      add :action_id, :text, null: false
      add :resource_type, :text
      add :resource_id, :text
      add :device_link_id, :text
      add :platform, :text
      # "accepted" | "rejected"
      add :status, :text, null: false
      add :reason, :text
      add :result, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    # Retry / double-tap dedupe: one SUCCESS outcome per (user, request_id).
    # Scoped by user so a forged/guessed request_id cannot read or block another
    # user's outcome. Partial (`status <> 'rejected'`) so recorded rejections are
    # audit-only and never dedupe/block a later corrected attempt.
    create unique_index(:mobile_action_outcomes, [:user_id, :request_id],
             where: "status <> 'rejected'",
             name: :mobile_action_outcomes_user_request_active_index
           )

    # Card-resolution guard: at most one ACCEPTED mutating outcome per card, so a
    # second device racing on the same card cannot both mutate the run.
    create unique_index(:mobile_action_outcomes, [:card_id],
             where: "status = 'accepted'",
             name: :mobile_action_outcomes_accepted_card_id_index
           )

    create index(:mobile_action_outcomes, [:user_id])
    create index(:mobile_action_outcomes, [:resource_type, :resource_id])
  end
end
