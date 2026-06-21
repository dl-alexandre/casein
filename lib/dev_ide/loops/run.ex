defmodule DevIDE.Loops.Run do
  @moduledoc """
  One self-improving loop: a `target` (typically a failing test id), a bounded
  number of rounds, and the baseline failures captured before the loop started
  (the out-of-sample reference used to detect regressions).

  A run owns an ordered ledger of `DevIDE.Loops.Attempt` rows. Statuses:

    * `:running`   — loop in progress
    * `:converged` — an attempt passed the frozen target, introduced no new
      failures, and survived the integrity verdict
    * `:exhausted` — `max_rounds` reached without convergence
    * `:failed`    — the loop could not run (e.g. no generator, sandbox error)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:running, :converged, :exhausted, :failed]

  @type t :: %__MODULE__{}

  schema "loop_runs" do
    field :workspace_id, :string
    field :target, :string
    field :status, Ecto.Enum, values: @statuses, default: :running
    field :max_rounds, :integer, default: 3
    field :converged, :boolean, default: false
    field :baseline_failures, {:array, :string}, default: []
    field :base_sha, :string
    field :metadata, :map, default: %{}

    has_many :attempts, DevIDE.Loops.Attempt, foreign_key: :loop_run_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workspace_id,
      :target,
      :status,
      :max_rounds,
      :converged,
      :baseline_failures,
      :base_sha,
      :metadata
    ])
    |> validate_required([:target])
    |> validate_number(:max_rounds, greater_than: 0)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses
end
