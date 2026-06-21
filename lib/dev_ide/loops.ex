defmodule DevIDE.Loops do
  @moduledoc """
  Loop-engineering context: self-improving coding loops over dev_ide's own
  codebase.

  The shape mirrors the quant "loop engineering" framework — generate a
  candidate, test it, score it, feed the result back, repeat — adapted to code:

      generate (LLM)  →  test (sandbox)  →  score (fitness fn)  →  feed back  →  repeat
                                                                          │
                                                            converge / exhaust

  This module owns persistence (the `Run` + append-only `Attempt` ledger). The
  orchestration lives in `DevIDE.Loops.Driver`, the scoring in
  `DevIDE.Loops.Scorer`, and the three seams (`Generator`, `Sandbox`,
  `Verifier`) are swappable so the loop is deterministic and unit-testable with
  the model-dependent step stubbed out.
  """

  import Ecto.Query

  alias DevIde.Repo
  alias DevIDE.Loops.{Attempt, Run}

  @spec create_run(map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def create_run(attrs) do
    %Run{}
    |> Run.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_run(integer()) :: Run.t() | nil
  def get_run(id), do: Repo.get(Run, id)

  @spec update_run(Run.t(), map()) :: {:ok, Run.t()} | {:error, Ecto.Changeset.t()}
  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
  end

  @doc "Append an immutable attempt to a run's ledger."
  @spec record_attempt(Run.t(), map()) :: {:ok, Attempt.t()} | {:error, Ecto.Changeset.t()}
  def record_attempt(%Run{id: run_id}, attrs) do
    %Attempt{}
    |> Attempt.changeset(Map.put(attrs, :loop_run_id, run_id))
    |> Repo.insert()
  end

  @spec list_attempts(Run.t()) :: [Attempt.t()]
  def list_attempts(%Run{id: run_id}) do
    Attempt
    |> where([a], a.loop_run_id == ^run_id)
    |> order_by([a], asc: a.iteration)
    |> Repo.all()
  end

  @doc "The highest-scoring attempt recorded for a run, or nil."
  @spec best_attempt(Run.t()) :: Attempt.t() | nil
  def best_attempt(%Run{id: run_id}) do
    Attempt
    |> where([a], a.loop_run_id == ^run_id and not is_nil(a.score))
    |> order_by([a], desc: a.score, desc: a.iteration)
    |> limit(1)
    |> Repo.one()
  end
end
