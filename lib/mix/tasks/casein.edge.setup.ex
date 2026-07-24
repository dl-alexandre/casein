defmodule Mix.Tasks.Casein.Edge.Setup do
  @moduledoc """
  Prepares or installs the optional Casein LAN HTTPS edge.

      mix casein.edge.setup
      mix casein.edge.setup --fix
      mix casein.edge.setup --listen-port 443 --backend-port 4443

  The edge uses systemd socket activation and `systemd-socket-proxyd` to forward
  `https://<hostname>.local/` on port 443 to Casein's LAN HTTPS listener on
  port 4443. TLS is not terminated by the edge; Casein still serves the mkcert
  certificate.
  """

  use Mix.Task
  use Boundary, classify_to: CaseinMix

  @shortdoc "Prepare or install the optional portless LAN HTTPS edge"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [
          fix: :boolean,
          listen_port: :integer,
          backend_host: :string,
          backend_port: :integer,
          unit_dir: :string,
          no_enable: :boolean
        ]
      )

    if invalid != [] do
      Mix.raise("invalid option(s): #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    proxyd = Casein.Setup.LanEdge.proxyd_path() || missing_proxyd!()
    fix? = Keyword.get(opts, :fix, false)
    enable? = not Keyword.get(opts, :no_enable, false)
    unit_dir = opts[:unit_dir] || Casein.Setup.LanEdge.unit_dir()

    listen_port =
      opts[:listen_port] || env_int("CASEIN_LAN_EDGE_PORT") || 443

    backend_port =
      opts[:backend_port] || env_int("CASEIN_LAN_HTTPS_PORT") || 4443

    backend_host =
      opts[:backend_host] || System.get_env("CASEIN_LAN_EDGE_BACKEND") || "127.0.0.1"

    prepared_dir =
      Path.join(System.tmp_dir!(), "casein-lan-edge-#{System.unique_integer([:positive])}")

    paths =
      Casein.Setup.LanEdge.write_units!(prepared_dir,
        listen_port: listen_port,
        backend_host: backend_host,
        backend_port: backend_port,
        proxyd_path: proxyd
      )

    Mix.shell().info("""
    Casein LAN edge units are ready.

    Files:
      socket:  #{paths.socket_path}
      service: #{paths.service_path}

    Proxy:
      :#{listen_port} -> #{backend_host}:#{backend_port}
    """)

    if fix? do
      install_or_print(paths, unit_dir, enable?)
    else
      print_manual_install(paths, unit_dir, enable?)
    end
  end

  defp missing_proxyd! do
    Mix.raise("""
    systemd-socket-proxyd was not found.

    On systemd Linux hosts it is usually installed with systemd itself.
    Arch package: systemd
    """)
  end

  defp install_or_print(paths, unit_dir, enable?) do
    commands = install_commands(paths, unit_dir, enable?, listen_port(paths.socket_path))

    case run_commands_noninteractive(commands) do
      :ok ->
        Mix.shell().info("Installed and activated Casein LAN edge.")

      {:error, failed_command, output} ->
        Mix.shell().info("Could not apply privileged edge setup non-interactively.")
        Mix.shell().info("Run these commands in an interactive shell:\n")
        print_commands(commands)
        Mix.shell().info("\nFirst failed command:\n  #{Enum.join(failed_command, " ")}")

        if String.trim(output) != "" do
          Mix.shell().info("\nOutput:\n#{String.trim(output)}")
        end
    end
  end

  defp print_manual_install(paths, unit_dir, enable?) do
    Mix.shell().info("Install with:\n")
    print_commands(install_commands(paths, unit_dir, enable?, listen_port(paths.socket_path)))
  end

  defp install_commands(paths, unit_dir, enable?, listen_port) do
    commands = [
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.socket_path,
        Path.join(unit_dir, Casein.Setup.LanEdge.socket_unit())
      ],
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.service_path,
        Path.join(unit_dir, Casein.Setup.LanEdge.service_unit())
      ],
      ["sudo", "systemctl", "daemon-reload"]
    ]

    commands =
      if enable? do
        commands ++ [["sudo", "systemctl", "enable", "--now", Casein.Setup.LanEdge.socket_unit()]]
      else
        commands
      end

    commands ++ firewall_commands(listen_port)
  end

  defp firewall_commands(port) do
    cond do
      System.find_executable("ufw") ->
        [["sudo", "ufw", "allow", "#{port}/tcp"]]

      System.find_executable("firewall-cmd") ->
        [
          ["sudo", "firewall-cmd", "--add-port=#{port}/tcp", "--permanent"],
          ["sudo", "firewall-cmd", "--reload"]
        ]

      true ->
        []
    end
  end

  defp listen_port(socket_path) do
    socket_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "=", parts: 2) do
        ["ListenStream", port] -> String.to_integer(String.trim(port))
        _ -> nil
      end
    end)
  end

  defp run_commands_noninteractive(commands) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      command = sudo_noninteractive(command)

      case System.cmd(List.first(command), tl(command), stderr_to_stdout: true) do
        {_out, 0} -> {:cont, :ok}
        {out, _status} -> {:halt, {:error, command, out}}
      end
    end)
  end

  defp sudo_noninteractive(["sudo" | rest]), do: ["sudo", "-n" | rest]
  defp sudo_noninteractive(command), do: command

  defp print_commands(commands) do
    Enum.each(commands, fn command ->
      Mix.shell().info("  #{Enum.join(command, " ")}")
    end)
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end
end
