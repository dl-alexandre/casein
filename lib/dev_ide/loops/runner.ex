defmodule DevIDE.Loops.Runner do
  @moduledoc """
  Runs a loop in the background, off the request path. A loop can take many
  minutes (each round builds and tests a disposable worktree), so it runs as a
  supervised task under the application's `DevIDE.TaskSupervisor`.

  (The loop is its own retry mechanism, so there is no job-level retry — a failed
  round is recorded as an attempt and the loop continues or exhausts.)

  The generator is the model seam: until one is configured
  (`config :dev_ide, DevIDE.Loops, generator: MyAdapter`) the driver records the
  run as `:failed` rather than guessing.
  """

  alias DevIDE.Loops
  alias DevIDE.Loops.Driver

  @doc "Start a supervised background loop for an already-created run."
  @spec start(Loops.Run.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(%Loops.Run{} = run, opts \\ []) do
    Task.Supervisor.start_child(DevIDE.TaskSupervisor, fn ->
      generator =
        Keyword.get(opts, :generator) ||
          Application.get_env(:dev_ide, DevIDE.Loops, [])[:generator]

      Driver.run_loop(run, Keyword.put(opts, :generator, generator))
    end)
  end
end
