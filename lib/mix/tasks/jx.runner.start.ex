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
    Mix.Task.run("loadpaths")
    opts = parse_args(args)
    validate_opts!(opts)
    start_runner_dependencies!()

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

  defp start_runner_dependencies! do
    for app <- [:logger, :crypto, :ssl, :public_key, :req, :erlexec] do
      case Application.ensure_all_started(app) do
        {:ok, _apps} ->
          :ok

        {:error, {failed_app, reason}} ->
          raise "failed to start #{failed_app}: #{inspect(reason)}"
      end
    end
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

  defp validate_opts!(opts) do
    unless present?(opts[:endpoint]) do
      raise ArgumentError, "runner endpoint required via --endpoint http://host:4000"
    end

    case opts[:runner_id] do
      nil ->
        :ok

      runner_id ->
        unless uuid?(runner_id) do
          raise ArgumentError, "runner id must be a UUID, got: #{inspect(runner_id)}"
        end
    end
  end

  defp runner_token!(opts) do
    opts[:token] ||
      System.get_env("DEV_IDE_RUNNER_TOKEN") ||
      System.get_env("DEV_IDE_API_TOKEN") ||
      raise ArgumentError,
            "runner token required via --token, DEV_IDE_RUNNER_TOKEN, or DEV_IDE_API_TOKEN"
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value))
  end

  defp uuid?(_value), do: false
end
