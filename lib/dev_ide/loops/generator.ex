defmodule DevIDE.Loops.Generator do
  @moduledoc """
  The "generate" seam — the only step that requires a model.

  A generator turns a target + accumulated feedback + the prior attempt's diff
  into a candidate diff. It does NOT run tests or judge itself: the deterministic
  `DevIDE.Loops.Sandbox` measures the result objectively, so a generator cannot
  game the metric by self-reporting a pass.

  dev_ide has no in-process LLM client today (agents are external MCP clients),
  so this behaviour is the integration point. Wire a concrete adapter — e.g. an
  Anthropic API client, or a bridge that drives an agent pane — to make the loop
  autonomous. Tests inject a stub generator.
  """

  @typedoc """
  Context handed to the generator each round.

    * `:target` — the failing test id / task to fix
    * `:baseline_failures` — failures that already existed (not the generator's fault)
    * `:feedback` — what went wrong last round (objective output + verdict reason)
    * `:prior_diff` — last round's diff, to build on or discard
    * `:iteration` — 1-based round number
    * `:root` — repo working copy, so a file-aware generator can read the code under test
  """
  @type context :: %{
          target: String.t(),
          baseline_failures: [String.t()],
          feedback: String.t(),
          prior_diff: String.t() | nil,
          iteration: pos_integer(),
          root: String.t() | nil
        }

  @typedoc "A candidate fix: a unified diff plus optional notes."
  @type result :: %{required(:diff) => String.t(), optional(:notes) => String.t()}

  @callback generate(context()) :: {:ok, result()} | {:error, term()}
end
