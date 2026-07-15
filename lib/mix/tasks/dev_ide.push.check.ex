defmodule Mix.Tasks.DevIDE.Push.Check do
  @moduledoc """
  Checks whether the configured server push provider can deliver to native platforms.

      mix dev_ide.push.check
      mix dev_ide.push.check --platform ios
      mix dev_ide.push.check --platform android --platform ios

  The task exits non-zero when any requested platform is not ready.
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: [DevIDE], exports: []

  alias DevIDE.Push.Diagnostics

  @shortdoc "Checks APNs/FCM push provider readiness"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [platform: :keep],
        aliases: [p: :platform]
      )

    platforms =
      opts
      |> Keyword.get_values(:platform)
      |> case do
        [] -> ["android", "ios"]
        values -> values
      end

    report = Diagnostics.report(platforms)

    Mix.shell().info("Push provider: #{inspect(report.provider)}")

    Enum.each(report.platforms, fn status ->
      case status.status do
        :ready ->
          Mix.shell().info("  #{status.platform}: ready")

        :not_ready ->
          Mix.shell().error(
            "  #{status.platform}: not ready (#{reason_to_string(status.reason)})"
          )

          Mix.shell().info("    #{status.hint}")
      end
    end)

    unless report.ready? do
      Mix.raise("push delivery is not ready for all requested platforms")
    end
  end

  defp reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_to_string(reason) when is_binary(reason), do: reason
  defp reason_to_string(reason), do: inspect(reason)
end
