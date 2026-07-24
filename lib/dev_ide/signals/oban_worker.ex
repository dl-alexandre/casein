defmodule Casein.Signals.ObanWorker do
  @moduledoc """
  `use Oban.Worker` wrapper that restores signals context in `perform/1`.

  Stamp context on insert with `ObanMiddleware.prepare_job/1` (or
  `ObanMiddleware.new_job/2`). Implement `execute/1` instead of `perform/1`.
  """

  @callback execute(Oban.Job.t()) :: Oban.Worker.result()

  defmacro __using__(opts) do
    quote do
      use Oban.Worker, unquote(opts)

      @behaviour Casein.Signals.ObanWorker

      @before_compile Casein.Signals.ObanWorker
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      alias Casein.Signals.ObanMiddleware
      alias Oban.Job

      @impl Oban.Worker
      def perform(%Job{} = job) do
        ObanMiddleware.perform_job(job, &__MODULE__.execute/1)
      end
    end
  end
end
