defmodule DevIDE.Loops.Attempt do
  @moduledoc """
  Immutable record of one loop iteration: the diff the generator produced, the
  objective evaluation the sandbox measured (compile / frozen target / held-out
  regressions, plus diff-derived gaming signals), the composite `score` and its
  `breakdown`, the integrity `verdict`, and the `feedback_in` that seeded this
  round.

  Rows are append-only (`updated_at: false`) — the attempt ledger is the durable
  evidence that the loop improved (or didn't) round over round.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @fields [
    :loop_run_id,
    :iteration,
    :diff,
    :files_changed,
    :compile_ok,
    :test_pass,
    :holdout_pass,
    :touched_test_files,
    :added_rescue,
    :new_failures,
    :score,
    :breakdown,
    :verdict_legit,
    :verdict_gamed,
    :verdict_reason,
    :feedback_in
  ]

  @type t :: %__MODULE__{}

  schema "loop_attempts" do
    field :iteration, :integer
    field :diff, :string
    field :files_changed, {:array, :string}, default: []
    field :compile_ok, :boolean
    field :test_pass, :boolean
    field :holdout_pass, :boolean
    field :touched_test_files, :boolean
    field :added_rescue, :boolean
    field :new_failures, {:array, :string}, default: []
    field :score, :integer
    field :breakdown, :string
    field :verdict_legit, :boolean
    field :verdict_gamed, :boolean
    field :verdict_reason, :string
    field :feedback_in, :string

    belongs_to :run, DevIDE.Loops.Run, foreign_key: :loop_run_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, @fields)
    |> validate_required([:loop_run_id, :iteration])
    |> foreign_key_constraint(:loop_run_id)
    |> unique_constraint([:loop_run_id, :iteration],
      name: :loop_attempts_loop_run_id_iteration_index
    )
  end
end
