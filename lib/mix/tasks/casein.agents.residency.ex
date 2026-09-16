defmodule Mix.Tasks.Casein.Agents.Residency do
  @shortdoc "Report which tmux pane holds each counted agent, and which have none"

  @moduledoc """
  Enumerate every agent process counted against the host budget and say which
  tmux pane holds it.

      mix casein.agents.residency
      mix casein.agents.residency --no-pane-only

  `Casein.Terminals.TmuxWindowJanitor` reaps idle tmux *windows*. An agent with
  no pane among its ancestors is outside that reach entirely — no timeout will
  ever collect it — yet it still consumes a slot in the
  `Casein.Terminals.HostCapacity` budget. This prints that population instead
  of leaving it to be counted by hand.

  Read-only: it kills nothing and changes no reaper policy.

  ## Options

    * `--no-pane-only` — list only the unreachable agents
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  alias Casein.Terminals.AgentResidency

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [no_pane_only: :boolean])

    case AgentResidency.report() do
      {:ok, report} -> print(report, Keyword.get(opts, :no_pane_only, false))
      {:error, reason} -> Mix.raise("could not read host processes: #{inspect(reason)}")
    end
  end

  defp print(report, no_pane_only) do
    residents =
      if no_pane_only,
        do: Enum.filter(report.residents, &(&1.residency == :no_pane)),
        else: report.residents

    Mix.shell().info(summary(report))

    residents
    |> Enum.sort_by(&{&1.residency, &1.command, &1.pid})
    |> Enum.each(&Mix.shell().info(line(&1)))
  end

  defp summary(report) do
    "#{report.total} agent(s): #{report.in_pane} in a pane, " <>
      "#{report.no_pane} with no pane (#{report.orphans} reparented to init)"
  end

  defp line(%{residency: :in_pane} = resident) do
    "  #{resident.pid}\t#{resident.command}\tin #{resident.pane.session}:#{resident.pane.pane_id}"
  end

  defp line(resident) do
    suffix = if resident.orphan?, do: " (ppid=1)", else: " (ppid=#{resident.ppid})"
    "  #{resident.pid}\t#{resident.command}\tNO PANE#{suffix}"
  end
end
