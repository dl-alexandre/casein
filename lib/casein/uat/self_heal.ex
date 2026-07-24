defmodule Casein.UAT.SelfHeal do
  @moduledoc """
  Handles Tier A `:drift` — an action target that no longer resolves. Drift is
  ambiguous: either the UI legitimately changed (re-author the trace) or it's a
  real regression (report it). This module re-engages the agent to classify, and:

    * `:regression` → returns `{:regression, run}`; the run stays failed/red.
    * `:ui_changed` → re-authors the trace and opens a **proposal PR**
      (`Casein.UAT.Proposal`) — never an in-place mutation. Returns `{:proposed, ref}`.

  Both the classifier and the re-author step are injected, so the decision logic
  is testable without an LLM or a git remote.
  """

  alias Casein.UAT.Proposal

  @type classification :: :regression | :ui_changed

  @doc """
  Resolve a drift `run` for `scenario_id` whose committed trace is `old_trace`.

  Options:

    * `:classifier` — `(run -> :regression | :ui_changed)` (required in practice)
    * `:reauthor` — `(-> {:ok, %{trace: Trace.t()}} | {:error, term})` producing the
      re-authored trace (wraps `Casein.UAT.Author`)
    * plus any `Casein.UAT.Proposal.propose/4` options (`:git`, `:trace_path`, ...)
  """
  @spec handle_drift(String.t(), Casein.UAT.Trace.t(), Casein.UAT.Run.t(), keyword()) ::
          {:regression, Casein.UAT.Run.t()} | {:proposed, term()} | {:error, term()}
  def handle_drift(scenario_id, old_trace, run, opts \\ []) do
    classifier = Keyword.get(opts, :classifier, &default_classifier/1)

    case classifier.(run) do
      :regression -> {:regression, run}
      :ui_changed -> propose_reheal(scenario_id, old_trace, run, opts)
      other -> {:error, {:bad_classification, other}}
    end
  end

  defp propose_reheal(scenario_id, old_trace, run, opts) do
    reauthor = Keyword.get(opts, :reauthor, &default_reauthor/0)

    with {:ok, %{trace: new_trace}} <- reauthor.() do
      meta = %{scenario_id: scenario_id, run_id: run_id(run), reason: "ui_changed"}

      case Proposal.propose(old_trace, new_trace, meta, opts) do
        {:ok, ref} -> {:proposed, ref}
        {:error, _} = err -> err
      end
    end
  end

  defp run_id(%{id: id}), do: to_string(id)
  defp run_id(_), do: "run"

  defp default_classifier(_run) do
    raise "Casein.UAT.SelfHeal needs a :classifier (regression vs ui_changed) — inject one."
  end

  defp default_reauthor do
    raise "Casein.UAT.SelfHeal needs a :reauthor step (wraps Author) — inject one."
  end
end
