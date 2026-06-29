defmodule DevIDE.UAT.Run do
  @moduledoc """
  One execution of a UAT scenario — Tier A (deterministic replay of a frozen
  `DevIDE.UAT.Trace`) or Tier B (agent-driven against the live release node).

  Stores run *history and verdicts* only; the trace definition itself lives in
  `priv/uat/<scenario>/trace.json` (see `DevIDE.UAT.Trace`).

  `session_id` is the `DevIDE.Previews.ControlSession` the run drove. It is a
  plain integer, not a DB foreign key: a Tier B run targets a session on the
  live release node, which may be a different instance than the one persisting
  this row, so a cross-instance FK constraint is not enforceable. The verdict
  validator (`DevIDE.UAT.Verdict`) still checks that every cited observation
  belongs to this `session_id`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @tiers [:tier_a, :tier_b]
  @outcomes [:pass, :fail, :drift, :errored]

  schema "uat_runs" do
    field :scenario_id, :string
    field :tier, Ecto.Enum, values: @tiers
    field :target_instance, :string
    field :session_id, :integer
    field :outcome, Ecto.Enum, values: @outcomes
    field :verdict, :map, default: %{}
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Valid tier values."
  @spec tiers() :: [atom()]
  def tiers, do: @tiers

  @doc "Valid outcome values."
  @spec outcomes() :: [atom()]
  def outcomes, do: @outcomes

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :scenario_id,
      :tier,
      :target_instance,
      :session_id,
      :outcome,
      :verdict,
      :started_at,
      :finished_at
    ])
    |> validate_required([:scenario_id, :tier])
  end
end
