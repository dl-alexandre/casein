defmodule Mix.Tasks.Casein.Worktrees.Unpushed do
  @shortdoc "List agent worktrees holding commits that exist on no origin ref"

  @moduledoc """
  Find agent worktrees whose work lives in exactly one place.

      mix casein.worktrees.unpushed
      mix casein.worktrees.unpushed --all

  A worktree under the OS temp root is aged out on a timer, and an agent
  working in one is told nothing about that. This lists the worktrees where
  that matters: commits reachable from `HEAD` and from no origin ref.

  Worst first. A detached HEAD with unpushed commits is reported as
  `UNRECOVERABLE` — a named branch survives the directory being deleted and a
  detached HEAD does not, so it is the one to rescue first. Its `HEAD` sha is
  printed, because while the directory exists that sha is all a rescue needs.

  Read-only: nothing is pushed, pruned, moved or deleted. Whose branch gets
  pushed is the owner's decision.

  ## Options

    * `--all` — include worktrees with nothing at stake
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  alias Casein.Worktrees.UnpushedAudit

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: [all: :boolean])

    entries = UnpushedAudit.audit()
    exposed = UnpushedAudit.exposed(entries)

    Mix.shell().info(summary(entries, exposed))

    shown = if Keyword.get(opts, :all, false), do: entries, else: exposed
    Enum.each(shown, &Mix.shell().info(line(&1)))
  end

  defp summary(entries, exposed) do
    at_risk = Enum.count(exposed, & &1.at_risk?)

    "#{length(entries)} agent worktree(s): #{length(exposed)} with work at stake, " <>
      "#{at_risk} of those on a root that is swept on a timer"
  end

  defp line(entry) do
    "  #{label(entry.verdict)}  #{entry.path}\t#{detail(entry)}#{risk(entry)}"
  end

  defp label(:unrecoverable), do: "UNRECOVERABLE"
  defp label(:unpushed), do: "unpushed    "
  defp label(:uncommitted), do: "uncommitted "
  defp label(:clean), do: "clean       "

  defp detail(%{verdict: :unrecoverable} = entry) do
    "#{entry.unpushed} commit(s) on no ref, detached at #{entry.head_sha}"
  end

  defp detail(%{verdict: :unpushed} = entry) do
    "#{entry.unpushed} commit(s) not on origin, on #{entry.branch || "(no branch)"}"
  end

  defp detail(%{verdict: :uncommitted}), do: "uncommitted changes"
  defp detail(_), do: "on origin, clean"

  defp risk(%{at_risk?: true}), do: "  [swept root]"
  defp risk(_), do: ""
end
