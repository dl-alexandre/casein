defmodule Mix.Tasks.Jx.Dossier.Export do
  use Boundary, classify_to: DevIDE

  @moduledoc """
  Export a complete fleet assignment dossier bundle.

  ## Usage

      mix jx.dossier.export ASSIGNMENT_ID --output tmp/dossier.json
  """

  use Mix.Task

  @shortdoc "Export a fleet assignment dossier bundle"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [output: :string],
        aliases: [o: :output]
      )

    case positional do
      [assignment_id] ->
        output = opts[:output] || default_output(assignment_id)

        case DevIDE.Fleet.DossierExport.write_assignment(assignment_id, output) do
          {:ok, path} ->
            Mix.shell().info(path)

          {:error, reason} ->
            Mix.raise("dossier export failed: #{inspect(reason)}")
        end

      _ ->
        Mix.raise("expected ASSIGNMENT_ID")
    end
  end

  defp default_output(assignment_id), do: "tmp/dossiers/#{assignment_id}.json"
end
