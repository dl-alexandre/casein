defmodule Mix.Tasks.Assignments.Replay do
  @moduledoc """
  Verify or repair assignment projections against their event streams.

  ## Usage

      mix assignments.replay              # verify all projections (read-only)
      mix assignments.replay --repair      # rebuild and overwrite projections

  ## Modes

    * `--verify` (default) — replays every event stream, compares the derived
      projection with the cached projection, and prints a mismatch report.
      Does **not** write to the projection cache.

    * `--repair` — replays every event stream and overwrites the projection
      cache.  Use this after schema changes, migrations, or when `verify`
      reports inconsistencies.

  ## Exit codes

    * `0` — all projections consistent (or repair completed successfully)
    * `1` — inconsistencies detected in verify mode
  """

  use Mix.Task

  alias DevIDE.Assignments.Replay

  @requirements ["app.start"]

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)

    if opts[:repair] do
      run_repair()
    else
      run_verify()
    end
  end

  defp run_repair do
    Mix.shell().info("Repair mode: rebuilding all projections from events…")

    :ok = Replay.rebuild_all()

    report = Replay.verify_all()

    Mix.shell().info("Repaired #{report.total} projection(s).")

    verify_after_repair(report)
  end

  defp run_verify do
    Mix.shell().info("Verify mode: comparing projections against event streams…")

    report = Replay.verify_all()

    if report.total == 0 do
      Mix.shell().info("No assignment events found.")
      exit({:shutdown, 0})
    end

    Mix.shell().info("")
    Mix.shell().info("Total assignments:     #{report.total}")
    Mix.shell().info("Consistent:              #{report.consistent}")
    Mix.shell().info("Inconsistent:            #{report.inconsistent}")
    Mix.shell().info("Missing from cache:      #{report.missing}")
    Mix.shell().info("")

    inconsistent = Enum.filter(report.details, &(&1.status == :inconsistent))
    missing = Enum.filter(report.details, &(&1.status == :missing))

    for detail <- inconsistent do
      Mix.shell().error(
        "  INCONSISTENT #{detail.assignment_id}: " <>
          "events→#{detail.from_events.state}, " <>
          "cache→#{if(detail.from_cache, do: detail.from_cache.state, else: "nil")} " <>
          "(#{detail.event_count} event(s))"
      )
    end

    for detail <- missing do
      Mix.shell().error(
        "  MISSING      #{detail.assignment_id}: " <>
          "no cached projection (#{detail.event_count} event(s))"
      )
    end

    if inconsistent == [] and missing == [] do
      Mix.shell().info("All projections are consistent with their event streams.")
      exit({:shutdown, 0})
    else
      Mix.shell().error("")

      Mix.shell().error(
        "Found #{length(inconsistent)} inconsistent and #{length(missing)} missing projection(s)."
      )

      Mix.shell().error("Run `mix assignments.replay --repair` to rebuild from events.")
      exit({:shutdown, 1})
    end
  end

  defp verify_after_repair(report) do
    inconsistent = Enum.filter(report.details, &(&1.status == :inconsistent))
    missing = Enum.filter(report.details, &(&1.status == :missing))

    if inconsistent == [] and missing == [] do
      Mix.shell().info("All projections are consistent after repair.")
      exit({:shutdown, 0})
    else
      Mix.shell().error(
        "Repair completed but #{length(inconsistent)} inconsistent and #{length(missing)} missing remain."
      )

      exit({:shutdown, 1})
    end
  end

  defp parse_args(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [repair: :boolean])
    opts
  end
end
