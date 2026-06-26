defmodule Mix.Tasks.DevIde.Lan.Down do
  @moduledoc """
  Stops the managed DevIDE LAN service and port-80 edge.

      mix dev_ide.lan.down
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: [DevIDE], exports: []

  @shortdoc "Stop the managed DevIDE LAN service"

  @impl Mix.Task
  def run(args) do
    config = parse_config!(args)
    commands = DevIDE.Setup.LanRuntime.down_commands(config)

    Mix.shell().info("Stopping DevIDE LAN...\n")

    case DevIDE.Setup.LanRuntime.run_commands_noninteractive(commands) do
      :ok ->
        config
        |> DevIDE.Setup.LanRuntime.status()
        |> DevIDE.Setup.LanRuntime.print_status(Mix.shell())

      {:error, failed_command, output} ->
        Mix.shell().info(DevIDE.Setup.LanRuntime.sudo_hint(commands))
        Mix.shell().info("\nFirst failed command:\n  #{Enum.join(failed_command, " ")}")

        if String.trim(output) != "" do
          Mix.shell().info("\nOutput:\n#{String.trim(output)}")
        end

        Mix.raise("could not stop DevIDE LAN")
    end
  end

  defp parse_config!(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          backend_port: :integer,
          host: :string,
          ip: :string,
          listen_port: :integer,
          unit_dir: :string,
          workspace: :string,
          workspaces_root: :string
        ]
      )

    if invalid != [] do
      Mix.raise("invalid option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    opts
    |> runtime_opts()
    |> DevIDE.Setup.LanRuntime.config()
  end

  defp runtime_opts(opts) do
    [
      backend_port: opts[:backend_port],
      lan_host: opts[:host],
      lan_ip: opts[:ip],
      listen_port: opts[:listen_port],
      unit_dir: opts[:unit_dir],
      workspace: opts[:workspace],
      workspaces_root: opts[:workspaces_root]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
