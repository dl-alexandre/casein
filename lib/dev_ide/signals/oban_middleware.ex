defmodule DevIDE.Signals.ObanMiddleware do
  @moduledoc """
  Oban insert/perform hooks that propagate `DevIDE.Signals.Context` via job `meta`.

  OSS Oban has no worker middleware chain; this module is the convention:
  stamp on insert (`prepare_job/1` or `use DevIDE.Signals.ObanWorker`), restore
  in `perform/1` via `perform_job/2` or the worker macro.
  """

  alias DevIDE.Signals.ObanContext

  @doc """
  Stamp the active correlation snapshot into an Oban job changeset's `meta`.

  Call before `Oban.insert/1`, or rely on `DevIDE.Signals.ObanWorker`'s `new/2`.
  """
  @spec prepare_job(Ecto.Changeset.t()) :: Ecto.Changeset.t()
  def prepare_job(%Ecto.Changeset{} = changeset), do: ObanContext.stamp_changeset(changeset)

  @doc """
  Build a job changeset and stamp the active signals context into `meta`.
  """
  @spec new_job(module(), map(), keyword()) :: Ecto.Changeset.t()
  def new_job(worker, args, opts \\ []) when is_atom(worker) and is_map(args) and is_list(opts) do
    args
    |> worker.new(opts)
    |> prepare_job()
  end

  @doc """
  Run a worker `perform/1` body under the job's captured signals context.
  """
  @spec perform_job(Oban.Job.t(), (Oban.Job.t() -> term())) :: term()
  def perform_job(%Oban.Job{} = job, fun) when is_function(fun, 1),
    do: ObanContext.perform(job, fun)
end