defmodule Mix.Tasks.Casein.JidoBench do
  @moduledoc """
  Repeatable OpenCode-vs-Jido resource benchmark (#1018).

      mix casein.jido_bench
      mix casein.jido_bench --n 4
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  @shortdoc "Benchmark Jido vs documented OpenCode resource cost"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [n: :integer, timeout_ms: :integer])
    Mix.Task.run("app.start")

    report = Casein.Agents.JidoBudgets.benchmark(opts)
    Mix.shell().info(inspect(report, pretty: true, limit: 40))

    if report.verdict.go? do
      Mix.shell().info("go")
    else
      Mix.shell().error("no-go rollback=#{inspect(report.verdict.rollback_trigger)}")
      Mix.raise("jido budget benchmark failed")
    end
  end
end
