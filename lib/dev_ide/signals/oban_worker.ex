defmodule DevIDE.Signals.ObanWorker do
  @moduledoc """
  `use Oban.Worker` wrapper that restores signals context in `perform/1`.

  Stamp context on insert with `ObanMiddleware.prepare_job/1` (or
  `ObanMiddleware.new_job/2`). Implement `execute/1` instead of `perform/1`.
  """

  defmacro __using__(opts) do
    quote do
      use Oban.Worker, unquote(opts)

      @before_compile DevIDE.Signals.ObanWorker
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      alias DevIDE.Signals.ObanMiddleware
      alias Oban.Job

      @impl Oban.Worker
      def perform(%Job{} = job) do
        ObanMiddleware.perform_job(job, &__MODULE__.execute/1)
      end

      @spec execute(Job.t()) :: Oban.Worker.result()
      def execute(%Job{}), do: :ok

      defoverridable execute: 1
    end
  end
end