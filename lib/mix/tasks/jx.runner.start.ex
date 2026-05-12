defmodule Mix.Tasks.Jx.Runner.Start do
  @moduledoc """
  Start a standalone DevIDE fleet runner.

  ## Usage

      DEV_IDE_RUNNER_TOKEN=TOKEN mix jx.runner.start --endpoint http://localhost:4000

  This is the Mix entrypoint for the intended `jx runner start` command shape.
  """

  use Mix.Task

  @shortdoc "Start a standalone fleet runner"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    opts = parse_args(args)

    {:ok, pid} =
      DevIDE.Fleet.RemoteRunner.start_link(
        endpoint: Keyword.fetch!(opts, :endpoint),
        token: runner_token!(opts),
        runner_id: opts[:runner_id],
        hostname: opts[:hostname],
        capabilities: Keyword.get(opts, :capabilities, ["workspace-command:v1"])
      )

    Mix.shell().info("Runner started: #{inspect(pid)}")
    Process.sleep(:infinity)
  end

  defp parse_args(args) do
    {opts, _, _} =
      OptionParser.parse(args,
        switches: [
          endpoint: :string,
          token: :string,
          runner_id: :string,
          hostname: :string,
          capability: :keep
        ]
      )

    opts
    |> Keyword.put(:capabilities, Keyword.get_values(opts, :capability))
    |> then(fn parsed ->
      if parsed[:capabilities] == [] do
        Keyword.put(parsed, :capabilities, ["workspace-command:v1"])
      else
        parsed
      end
    end)
  end

  defp runner_token!(opts) do
    opts[:token] ||
      System.get_env("DEV_IDE_RUNNER_TOKEN") ||
      System.get_env("DEV_IDE_API_TOKEN") ||
      raise ArgumentError,
            "runner token required via --token, DEV_IDE_RUNNER_TOKEN, or DEV_IDE_API_TOKEN"
  end
end
