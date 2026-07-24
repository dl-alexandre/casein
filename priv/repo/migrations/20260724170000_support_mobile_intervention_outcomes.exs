defmodule Casein.Repo.Migrations.SupportMobileInterventionOutcomes do
  use Ecto.Migration

  def up do
    drop_if_exists index(:mobile_action_outcomes, [:card_id],
                     name: :mobile_action_outcomes_accepted_card_id_index
                   )

    create unique_index(:mobile_action_outcomes, [:card_id],
             where: "status = 'accepted' AND action_id <> 'follow_up'",
             name: :mobile_action_outcomes_accepted_card_id_index
           )

    create unique_index(:mobile_action_outcomes, [:card_id],
             where: "status IN ('processing', 'accepted') AND action_id = 'follow_up'",
             name: :mobile_action_outcomes_follow_up_card_id_index
           )
  end

  def down do
    drop_if_exists index(:mobile_action_outcomes, [:card_id],
                     name: :mobile_action_outcomes_follow_up_card_id_index
                   )

    drop_if_exists index(:mobile_action_outcomes, [:card_id],
                     name: :mobile_action_outcomes_accepted_card_id_index
                   )

    create unique_index(:mobile_action_outcomes, [:card_id],
             where: "status IN ('processing', 'accepted')",
             name: :mobile_action_outcomes_accepted_card_id_index
           )
  end
end
