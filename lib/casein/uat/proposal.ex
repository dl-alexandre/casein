defmodule Casein.UAT.Proposal do
  @moduledoc """
  Self-heal proposals. When Tier A replay drifts because the UI legitimately
  changed (not a regression), the agent re-authors the trace and this module
  proposes the change as a **reviewable PR** — never an in-place mutation of the
  committed trace. A human merges or dismisses it; CI stays red until then.

  `build/3` produces the proposal document (old + new trace + per-step diff);
  `propose/4` publishes it through a `Casein.UAT.Git` implementation, writing the
  proposal artifact and the updated trace onto a fresh `uat/reheal-<scenario>`
  branch.
  """

  alias Casein.UAT.{Git, Step, Trace}

  @doc "Build the proposal document comparing `old` and `new` traces."
  @spec build(Trace.t(), Trace.t(), map()) :: map()
  def build(%Trace{} = old, %Trace{} = new, meta) do
    %{
      "scenario_id" => meta[:scenario_id] || old.id,
      "run_id" => meta[:run_id],
      "reason" => meta[:reason] || "ui_changed",
      "old_trace" => Trace.to_map(old),
      "new_trace" => Trace.to_map(new),
      "step_diff" => diff_steps(old.steps, new.steps)
    }
  end

  @doc """
  Publish a proposal as a PR. Options:

    * `:git` — a `Casein.UAT.Git` impl (default `Casein.UAT.Git.System`)
    * `:trace_path` — path of the committed trace to update on the branch
      (default `priv/uat/<scenario>/trace.json`)
    * `:proposal_path` — path for the proposal artifact on the branch
      (default `priv/uat/proposals/<scenario>-<run>.json`)
  """
  @spec propose(Trace.t(), Trace.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def propose(%Trace{} = old, %Trace{} = new, meta, opts \\ []) do
    git = Keyword.get(opts, :git, Git.System)
    proposal = build(old, new, meta)
    scenario = proposal["scenario_id"]
    run_id = proposal["run_id"] || "run"

    # scenario_id and run_id build file paths on the reheal branch — reject any
    # value that could escape priv/uat (defense in depth; Manifest also validates).
    if not safe_segment?(scenario) or not safe_segment?(to_string(run_id)) do
      raise ArgumentError,
            "unsafe scenario_id/run_id for proposal path: #{inspect({scenario, run_id})}"
    end

    trace_path = Keyword.get(opts, :trace_path, "priv/uat/#{scenario}/trace.json")

    proposal_path =
      Keyword.get(opts, :proposal_path, "priv/uat/proposals/#{scenario}-#{run_id}.json")

    git.propose(%{
      branch: "uat/reheal-#{scenario}",
      files: [
        {trace_path, Trace.to_json(new)},
        {proposal_path, Jason.encode!(proposal, pretty: true)}
      ],
      title: "UAT self-heal: re-author #{scenario} trace",
      body: proposal_body(proposal)
    })
  end

  # Per-index step comparison; reports added/removed/changed positions. `from`
  # is audit-only provenance (unique per authoring session), so it is stripped
  # before comparison — otherwise every re-authored step would show as changed.
  defp diff_steps(old_steps, new_steps) do
    old_maps = Enum.map(old_steps, &comparable/1)
    new_maps = Enum.map(new_steps, &comparable/1)
    max = max(length(old_maps), length(new_maps))

    Enum.flat_map(0..max, fn
      i when i >= max ->
        []

      i ->
        old = Enum.at(old_maps, i)
        new = Enum.at(new_maps, i)
        if old == new, do: [], else: [%{"index" => i, "old" => old, "new" => new}]
    end)
  end

  defp comparable(step), do: step |> Step.to_map() |> Map.delete("from")

  defp safe_segment?(segment), do: is_binary(segment) and segment =~ ~r/\A[a-z0-9_-]+\z/i

  defp proposal_body(proposal) do
    changed = length(proposal["step_diff"])

    """
    Automated UAT self-heal proposal for `#{proposal["scenario_id"]}`.

    Reason: #{proposal["reason"]} (drift classified as a legitimate UI change).
    Run: #{proposal["run_id"]}
    Changed steps: #{changed}

    Review the per-step diff in the proposal artifact. Merging accepts the
    re-authored trace; dismissing keeps the original and flags the drift for
    manual triage. CI stays red until this is resolved.
    """
  end
end
