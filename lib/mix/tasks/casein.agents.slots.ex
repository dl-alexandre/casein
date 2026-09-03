defmodule Mix.Tasks.Casein.Agents.Slots do
  @shortdoc "Show which workspace holds each slot of the host agent budget"

  @moduledoc """
  Attribute the host agent budget to the workspaces holding it.

      mix casein.agents.slots

  `Casein.Terminals.HostCapacity` enforces `CASEIN_AGENT_MAX_TOTAL` as a single
  global first-come counter. `CASEIN_AGENT_MAX_PER_USER` cannot refine it here:
  every agent runs as the same OS user, so the per-user axis is inert by
  construction and `ps` attributes nothing.

  The tmux session holding an agent is the only workspace identity available,
  so that is what this reports — the same walk
  `mix casein.agents.residency` uses, grouped by workspace instead of listed
  per agent. Agents no pane holds are reported as unattributed: they consume
  budget that no per-workspace reservation could reserve.

  Read-only, and it decides nothing. A ceiling or a floor is a host-owner
  decision; this is the measurement it needs.
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  alias Casein.Terminals.AgentResidency

  @impl Mix.Task
  def run(_argv) do
    case AgentResidency.report() do
      {:ok, report} -> print(report)
      {:error, reason} -> Mix.raise("could not read host processes: #{inspect(reason)}")
    end
  end

  defp print(report) do
    Mix.shell().info("#{report.total} of the agent budget held, by workspace:")

    report.by_workspace
    |> Enum.sort_by(fn {workspace, count} -> {-count, workspace || ""} end)
    |> Enum.each(fn {workspace, count} -> Mix.shell().info(line(workspace, count, report)) end)

    if report.no_pane > 0 do
      Mix.shell().info(
        "\n#{report.no_pane} unattributed slot(s) hold budget no reservation can cover."
      )
    end
  end

  defp line(nil, count, report) do
    "  #{pad(count)}  (unattributed — no tmux pane)#{share(count, report)}"
  end

  defp line(workspace, count, report) do
    "  #{pad(count)}  #{workspace}#{share(count, report)}"
  end

  defp pad(count), do: String.pad_leading(Integer.to_string(count), 3)

  defp share(_count, %{total: 0}), do: ""
  defp share(count, %{total: total}), do: "\t#{round(count * 100 / total)}%"
end
