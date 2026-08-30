defmodule Casein.Release.AgentRuntimeScripts do
  @moduledoc """
  Which of `scripts/` ships inside the release's `priv/scripts`.

  Worker launches are API calls made by the release process, so the launchers
  cannot assume an operator checkout is present — the release carries its own
  copy of the agent runtime. `mix.exs` used to stage `scripts/lib` from a
  hand-maintained allowlist, which meant a launcher could start sourcing a new
  helper, pass the whole suite (tests run against the checkout), and then fail
  fleet-wide the moment the release landed (#20159: `spawn-agent-worker.sh`
  could not source `agent-budget.sh`). The staged set is now *derived* from the
  shipped scripts: every `scripts/lib/<name>` the top-level launchers mention,
  transitively through the helpers they pull in.
  """

  @top_level ~w(
    launch-casein-agent.sh
    spawn-agent-worker.sh
    materialize-agent-mcp.sh
    casein-curl.sh
    casein-agent-state.sh
    casein-codex-notify.sh
  )

  # A concrete file name only — `scripts/lib/<name>` placeholders in prose do
  # not match, so documentation cannot invent a dependency.
  @reference ~r{scripts/lib/([A-Za-z0-9][A-Za-z0-9_.-]*)}

  @doc "Top-level scripts copied to `priv/scripts` (sources of the closure)."
  @spec top_level() :: [String.t()]
  def top_level, do: @top_level

  @doc """
  Sorted `scripts/lib` file names the shipped launchers depend on, transitively.

  Raises when a launcher references a helper that does not exist under
  `<root>/scripts/lib` — that is a broken launcher, not a file to skip.
  """
  @spec lib_closure(Path.t()) :: [String.t()]
  def lib_closure(root) do
    seeds = Enum.map(@top_level, &Path.join([root, "scripts", &1]))
    walk(seeds, root, MapSet.new()) |> Enum.sort()
  end

  @doc "`scripts/lib/<name>` references found in one file, deduplicated."
  @spec references(Path.t()) :: [String.t()]
  # sobelow_skip ["Traversal.FileModule"]
  def references(path) do
    @reference
    |> Regex.scan(File.read!(path), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
  end

  defp walk([], _root, seen), do: MapSet.to_list(seen)

  defp walk([path | rest], root, seen) do
    {next, seen} =
      path
      |> references()
      |> Enum.reject(&MapSet.member?(seen, &1))
      |> Enum.reduce({[], seen}, fn name, {queue, seen} ->
        lib_path = Path.join([root, "scripts", "lib", name])

        unless File.regular?(lib_path) do
          raise ArgumentError,
                "#{Path.relative_to(path, root)} references scripts/lib/#{name}, " <>
                  "which does not exist — the release would ship a launcher that cannot source it"
        end

        {[lib_path | queue], MapSet.put(seen, name)}
      end)

    walk(next ++ rest, root, seen)
  end
end
