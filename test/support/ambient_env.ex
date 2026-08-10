defmodule Casein.Test.AmbientEnv do
  @moduledoc """
  Scrubs operator-shell `CASEIN_*` variables out of the test VM (#248).

  Product code still reads many knobs via `System.get_env/1` (env-first or
  env-fallback). A suite launched from a paired agent pane inherits ~70
  operator exports (`CASEIN_ON_DEVBOX`, `CASEIN_HTTP_SOCKET`, live API tokens,
  host worktree roots, …). Those leak into product paths and red unrelated
  tests on a shared box while CI stays green.

  `config/test.exs` runs an identical scrub **before** the application boots
  (mix starts the app before `test_helper.exs`). Call `scrub!/0` again from
  `test/test_helper.exs` so the keep-list stays owned by this module and
  hermetic tests can re-apply it. Tests that need a specific `CASEIN_*` value
  set it themselves (and restore with `env: [{"VAR", nil}]` when spawning
  children — `System.cmd/3` merges `env:` with the parent).

  Keep-list is intentionally small: only knobs that select the suite's own
  harness, not product behaviour. When you change it, update the twin loop in
  `config/test.exs` too.
  """

  @keep_exact MapSet.new([
                # Compile/config adapter pin (desktop packages compile sqlite).
                "CASEIN_REPO_ADAPTER",
                # Optional shared tmp root for large fixtures on constrained hosts.
                "CASEIN_TEST_TMPDIR"
              ])

  @keep_prefixes [
    # Gate skip tokens set by pre-push cheap phase (`CASEIN_GATE_SKIP_*`).
    "CASEIN_GATE_",
    # Hermetic script-test fixtures (`CASEIN_TEST_REPO`, `CASEIN_TEST_RECORD`, …).
    "CASEIN_TEST_"
  ]

  @doc """
  Delete every ambient `CASEIN_*` export that is not on the keep-list.

  Returns the list of deleted variable names (sorted) for assertions.
  """
  @spec scrub!() :: [String.t()]
  def scrub! do
    deleted =
      System.get_env()
      |> Enum.reduce([], fn {key, _value}, acc ->
        if casein_var?(key) and not keep?(key) do
          System.delete_env(key)
          [key | acc]
        else
          acc
        end
      end)
      |> Enum.sort()

    deleted
  end

  @doc false
  @spec keep?(String.t()) :: boolean()
  def keep?(key) when is_binary(key) do
    MapSet.member?(@keep_exact, key) or Enum.any?(@keep_prefixes, &String.starts_with?(key, &1))
  end

  @doc false
  @spec casein_var?(String.t()) :: boolean()
  def casein_var?(key) when is_binary(key), do: String.starts_with?(key, "CASEIN_")
end
