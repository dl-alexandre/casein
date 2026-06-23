defmodule DevIDE.LoopsTest.StubSeams do
  @moduledoc false
  # Shared loop generator stubs for runner/driver tests. Top-level modules so
  # Task.Supervisor-spawned processes can resolve them in isolated test runs.

  defmodule StubGenerator do
    @behaviour DevIDE.Loops.Generator
    @impl true
    def generate(%{iteration: i}), do: {:ok, %{diff: "round-#{i}", notes: "stub"}}
  end

  defmodule RaisingGenerator do
    @behaviour DevIDE.Loops.Generator
    @impl true
    def generate(_ctx), do: raise("generator must not run when quarantine denies")
  end

  defmodule FastExhaustSandbox do
    @behaviour DevIDE.Loops.Sandbox
    @impl true
    def evaluate(_diff, _ctx) do
      {:ok,
       %{
         compile_ok: false,
         test_pass: false,
         holdout_pass: false,
         touched_test_files: false,
         added_rescue: false,
         new_failures: [],
         files_changed: [],
         output_excerpt: "stub"
       }}
    end
  end
end
