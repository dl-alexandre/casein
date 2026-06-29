defmodule DevIDE.UAT.Author do
  @moduledoc """
  The acceptance-agent harness. Given a natural-language criterion and a preview
  session, it runs the agent (which drives the `preview_*` MCP tools), validates
  the returned verdict for grounding (`DevIDE.UAT.Verdict` — the guardrail), and,
  only on a genuinely-grounded pass, freezes the session's audit trail into a
  replayable `DevIDE.UAT.Trace` (`DevIDE.UAT.Freeze`).

  The agent itself is injected (`:agent`) so the harness — validate-then-freeze —
  is testable without an LLM. The real agent driver is unverified scaffolding;
  callers in CI inject the live MCP driver.
  """

  alias DevIDE.UAT.{Freeze, Verdict}

  @type agent_fn :: (String.t(), integer() -> map())

  @doc """
  Author a trace for `criterion` against `session_id`.

  `attrs` is the trace metadata for the freeze step (`:id`, `:criterion`, ...).
  Options: `:agent` (required in practice), `:repo`, `:artifacts_root` (forwarded
  to the verdict validator).

  Returns `{:ok, %{trace: Trace.t(), verdict: map()}}`, `{:error, {:not_passed,
  verdict}}` when the agent did not establish a grounded pass, or `{:error,
  {:invalid_verdict, errors}}` when the verdict is malformed.
  """
  @spec author(String.t(), integer(), map(), keyword()) ::
          {:ok, %{trace: DevIDE.UAT.Trace.t(), verdict: map()}} | {:error, term()}
  def author(criterion, session_id, attrs, opts \\ []) do
    agent = Keyword.get(opts, :agent, &default_agent/2)
    verdict = agent.(criterion, session_id)

    case Verdict.validate(verdict, session_id, opts) do
      {:ok, %{"passed" => true} = validated} ->
        freeze(session_id, attrs, validated, opts)

      {:ok, validated} ->
        {:error, {:not_passed, validated}}

      {:error, errors} ->
        {:error, {:invalid_verdict, errors}}
    end
  end

  defp freeze(session_id, attrs, validated, opts) do
    case Freeze.from_session(session_id, attrs, opts) do
      {:ok, trace} -> {:ok, %{trace: trace, verdict: validated}}
      {:error, _} = err -> err
    end
  end

  defp default_agent(_criterion, _session_id) do
    raise "DevIDE.UAT.Author needs an :agent (the live MCP driver). " <>
            "The real driver is unverified scaffolding — inject one explicitly."
  end
end
