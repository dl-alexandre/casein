defmodule Mix.Tasks.DevIde.Lan.Up do
  @moduledoc """
  Starts DevIDE LAN HTTP mode as a managed local service.

      mix dev_ide.lan.up

  This installs or updates:

    * `devide-lan.service` - the loopback Phoenix backend
    * `devide-lan-http-edge.socket` - privileged port 80
    * `devide-lan-http-edge.service` - socket proxy to the backend

  Administrator access is required for systemd unit installation and port 80.
  The Mix task itself should still be run as the normal developer user.
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: [DevIDE], exports: []

  @shortdoc "Start the product-like DevIDE LAN HTTP service"

  @impl Mix.Task
  def run(args) do
    config = parse_config!(args)

    case DevIDE.Setup.LanRuntime.validate(config) do
      :ok -> :ok
      {:error, message} -> Mix.raise(message)
    end

    File.mkdir_p!(Path.expand(Path.join(config.workspaces_root, config.workspace)))

    paths = DevIDE.Setup.LanRuntime.prepare_units!(config)
    commands = DevIDE.Setup.LanRuntime.install_commands(paths, config)

    Mix.shell().info("Installing and starting DevIDE LAN...\n")

    case DevIDE.Setup.LanRuntime.run_commands_noninteractive(commands) do
      :ok ->
        timeout_ms = config.timeout_seconds * 1_000
        status = DevIDE.Setup.LanRuntime.wait_until_ready(config, timeout_ms)
        DevIDE.Setup.LanRuntime.print_status(status, Mix.shell())

        unless status.ready? do
          Mix.raise("""
          DevIDE LAN did not become ready within #{config.timeout_seconds}s.

          Inspect the backend with:

            journalctl -u devide-lan.service -n 100 --no-pager
          """)
        end

      {:error, failed_command, output} ->
        Mix.shell().info(DevIDE.Setup.LanRuntime.sudo_hint(commands))
        Mix.shell().info("\nFirst failed command:\n  #{Enum.join(failed_command, " ")}")

        if String.trim(output) != "" do
          Mix.shell().info("\nOutput:\n#{String.trim(output)}")
        end

        Mix.raise("could not install or start DevIDE LAN")
    end
  end

  defp parse_config!(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          backend_port: :integer,
          build_path: :string,
          host: :string,
          ip: :string,
          listen_port: :integer,
          mise_path: :string,
          no_firewall: :boolean,
          proxyd_path: :string,
          timeout: :integer,
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
    |> Keyword.put(:timeout_seconds, Keyword.get(opts, :timeout, 30))
    |> DevIDE.Setup.LanRuntime.config()
  end

  defp runtime_opts(opts) do
    [
      backend_port: opts[:backend_port],
      build_path: opts[:build_path],
      firewall?: not Keyword.get(opts, :no_firewall, false),
      lan_host: opts[:host],
      lan_ip: opts[:ip],
      listen_port: opts[:listen_port],
      mise_path: opts[:mise_path],
      proxyd_path: opts[:proxyd_path],
      unit_dir: opts[:unit_dir],
      workspace: opts[:workspace],
      workspaces_root: opts[:workspaces_root]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
