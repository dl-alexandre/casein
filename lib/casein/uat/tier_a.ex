defmodule Casein.UAT.TierA do
  @moduledoc """
  Tier A orchestration: for each eligible scenario, boot an ephemeral instance,
  replay the frozen trace deterministically (no LLM), and tear the instance down
  — always, even if replay raises.

  A scenario that is not `:tier_a`-eligible (declared `:tier_b`-only because it
  can't be made deterministic) is **skipped**, not failed.

  The `exit_code/1` mapping lets the `mix uat.tier_a` CI hook distinguish a real
  regression (`:fail`) from drift that needs self-heal (`:drift`) from infra
  failure (`:errored`) — none of which silently green.
  """

  alias Casein.UAT.{Instance, Manifest, Replay, Trace}

  @doc """
  Run one scenario from an already-loaded manifest + trace against `workspace`.

  Returns the `Replay.run/3` result (`{:ok, %Run{}}`), `{:skipped, :tier_b_only}`,
  or `{:error, {:boot_failed, reason}}`.
  """
  @spec run_scenario(Manifest.t(), Trace.t(), map(), keyword()) ::
          {:ok, Casein.UAT.Run.t()} | {:skipped, :tier_b_only} | {:error, term()}
  def run_scenario(%Manifest{} = manifest, %Trace{} = trace, workspace, opts \\ []) do
    if Manifest.tier_eligible?(manifest, :tier_a) do
      boot_and_replay(manifest, trace, workspace, opts)
    else
      {:skipped, :tier_b_only}
    end
  end

  defp boot_and_replay(manifest, trace, workspace, opts) do
    case Instance.boot(manifest, opts) do
      {:ok, instance} ->
        try do
          # Only replay-relevant opts reach Replay; instance opts (:runner,
          # :port, :workspaces_root, ...) must not leak into open_session.
          replay_opts = Keyword.take(opts, [:repo, :actor_id]) ++ [tier: :tier_a]
          Replay.run(trace, workspace, replay_opts)
        after
          Instance.teardown(instance)
        end

      {:error, reason} ->
        {:error, {:boot_failed, reason}}
    end
  end

  @doc "Load `manifest.json` + `trace.json` from `scenario_dir` and run the scenario."
  @spec run_path(String.t(), map(), keyword()) :: term()
  # UAT scenario directories are operator-owned committed fixtures, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def run_path(scenario_dir, workspace, opts \\ []) do
    with {:ok, manifest} <- Manifest.load(Path.join(scenario_dir, "manifest.json")),
         {:ok, trace_json} <- File.read(Path.join(scenario_dir, "trace.json")),
         {:ok, trace} <- decode_trace(trace_json) do
      run_scenario(manifest, trace, workspace, Keyword.put(opts, :scenario_dir, scenario_dir))
    end
  end

  # Trace.from_json/1 raises on malformed JSON or an unknown step kind; contain it
  # so one bad scenario file is reported, not fatal to the whole batch.
  defp decode_trace(trace_json) do
    {:ok, Trace.from_json(trace_json)}
  rescue
    e -> {:error, {:bad_trace, Exception.message(e)}}
  end

  @doc "Discover every scenario dir under `root` (those containing a manifest.json)."
  @spec scenario_dirs(String.t()) :: [String.t()]
  def scenario_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.exists?(Path.join(&1, "manifest.json")))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc """
  Map a batch of `{scenario_id, result}` pairs to a process exit code:

    * `0` — all passed or skipped
    * `1` — at least one `:fail` (regression)
    * `2` — at least one `:drift` (needs self-heal), no fails
    * `3` — at least one `:errored`/`{:error, _}` (infra), no fails/drifts
  """
  @spec exit_code([{String.t(), term()}]) :: 0..3
  def exit_code(results) do
    outcomes = Enum.map(results, fn {_id, result} -> outcome_of(result) end)

    cond do
      :fail in outcomes -> 1
      :drift in outcomes -> 2
      :errored in outcomes or :error in outcomes -> 3
      true -> 0
    end
  end

  defp outcome_of({:ok, %{outcome: outcome}}), do: outcome
  defp outcome_of({:skipped, _}), do: :skipped
  defp outcome_of({:error, _}), do: :error
  defp outcome_of(_), do: :error
end
