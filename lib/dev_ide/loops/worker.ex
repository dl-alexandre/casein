defmodule DevIDE.Loops.Worker do
  @moduledoc """
  Runs a loop in the background. A loop can take many minutes (each round
  cold-builds and tests a worktree), so it belongs off the request path.

  `max_attempts: 1` — a loop is itself the retry mechanism; Oban-retrying a whole
  loop would just duplicate work. The generator is the model seam: until one is
  configured (`config :dev_ide, DevIDE.Loops, generator: MyAdapter`) the driver
  records the run as `:failed` rather than guessing.
  """
  use Oban.Worker, queue: :loops, max_attempts: 1

  alias DevIDE.Loops
  alias DevIDE.Loops.Driver

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    case Loops.get_run(run_id) do
      nil ->
        {:cancel, "loop run #{run_id} not found"}

      run ->
        generator = Application.get_env(:dev_ide, DevIDE.Loops, [])[:generator]
        {_outcome, _run} = Driver.run_loop(run, generator: generator)
        :ok
    end
  end

  @doc "Enqueue a background loop for an already-created run."
  @spec enqueue(DevIDE.Loops.Run.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%Loops.Run{id: run_id}) do
    %{run_id: run_id}
    |> new()
    |> Oban.insert()
  end
end
