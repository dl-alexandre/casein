defmodule Mix.Tasks.Uat.TierA do
  @shortdoc "Run Tier A UAT scenarios (deterministic replay of frozen traces)"
  @moduledoc """
  CI entrypoint for Tier A UAT. Discovers scenarios under a root (default
  `priv/uat`), runs each `:tier_a`-eligible one through `DevIDE.UAT.TierA`, and
  exits with a code that distinguishes the outcomes (see `TierA.exit_code/1`):
  `0` clean, `1` regression, `2` drift (needs self-heal), `3` infra/not-configured.

      mix uat.tier_a --dry-run        # list scenarios + tier eligibility, boot nothing
      mix uat.tier_a                  # run (needs :dev_ide, :uat_sandbox_workspace)
      mix uat.tier_a priv/uat/checkout

  A real run boots ephemeral instances, so it needs a sandbox workspace map
  configured as `config :dev_ide, :uat_sandbox_workspace, %{...}` — the live-smoke
  wiring (Phase 2). Without it the task lists and exits `3` rather than pretending.
  """

  use Mix.Task
  # Mix tasks aren't a domain boundary. Keep this as a top-level boundary
  # that may depend on the DevIDE domain. Manual classification is reserved
  # for tasks grouped under the uniquely named `DevIDEMix` boundary.
  # targeting a mix boundary, and emits "unknown boundary" otherwise.)
  use Boundary, top_level?: true, deps: [DevIDE], exports: :all

  alias DevIDE.UAT.{Manifest, TierA}

  @impl true
  def run(argv) do
    {opts, paths, _} = OptionParser.parse(argv, strict: [dry_run: :boolean])
    root = List.first(paths) || "priv/uat"
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started(:dev_ide)

    dirs = scenario_dirs(root, paths)

    if dirs == [] do
      Mix.shell().info("No UAT scenarios found under #{root}")
    else
      list(dirs)
      unless opts[:dry_run], do: execute(dirs)
    end
  end

  defp scenario_dirs(root, [single]) do
    if File.exists?(Path.join(single, "manifest.json")),
      do: [single],
      else: TierA.scenario_dirs(root)
  end

  defp scenario_dirs(root, _), do: TierA.scenario_dirs(root)

  defp list(dirs) do
    Mix.shell().info("Tier A UAT scenarios:")
    Enum.each(dirs, &list_one/1)
  end

  defp list_one(dir) do
    case Manifest.load(Path.join(dir, "manifest.json")) do
      {:ok, m} ->
        eligible =
          if Manifest.tier_eligible?(m, :tier_a), do: "tier_a", else: "SKIP (tier_b-only)"

        Mix.shell().info("  - #{m.scenario_id}: #{eligible}")

      {:error, reason} ->
        Mix.shell().error("  - #{Path.basename(dir)}: invalid manifest (#{inspect(reason)})")
    end
  end

  defp execute(dirs) do
    case Application.get_env(:dev_ide, :uat_sandbox_workspace) do
      nil ->
        Mix.shell().error(
          "Real runs need config :dev_ide, :uat_sandbox_workspace (Phase 2 live-smoke). Use --dry-run."
        )

        System.halt(3)

      workspace ->
        results =
          Enum.map(dirs, fn dir -> {Path.basename(dir), TierA.run_path(dir, workspace)} end)

        report(results)
        System.halt(TierA.exit_code(results))
    end
  end

  defp report(results) do
    Enum.each(results, fn {id, result} ->
      Mix.shell().info("  #{id}: #{inspect(summarize(result))}")
    end)
  end

  defp summarize({:ok, %{outcome: outcome}}), do: outcome
  defp summarize(other), do: other
end
