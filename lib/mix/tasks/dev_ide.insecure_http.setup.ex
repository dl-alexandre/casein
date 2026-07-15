defmodule Mix.Tasks.DevIDE.InsecureHttp.Setup do
  @moduledoc """
  Prepares or installs the optional insecure DevIDE LAN HTTP edge.

      mix dev_ide.insecure_http.setup
      mix dev_ide.insecure_http.setup --fix

  This intentionally exposes DevIDE over plain HTTP on the LAN:

      http://<hostname>.local/

  Use only on trusted networks for short-lived dogfooding. Prefer the HTTPS LAN
  edge for normal use.
  """

  use Mix.Task
  use Boundary, top_level?: true, deps: [DevIDE], exports: []

  @shortdoc "Prepare or install the intentionally insecure LAN HTTP edge"

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

    proxyd = DevIDE.Setup.InsecureHttpEdge.proxyd_path() || missing_proxyd!()
    fix? = Keyword.get(opts, :fix, false)
    enable? = not Keyword.get(opts, :no_enable, false)
    unit_dir = opts[:unit_dir] || DevIDE.Setup.InsecureHttpEdge.unit_dir()
    listen_port = opts[:listen_port] || env_int("DEV_IDE_LAN_INSECURE_HTTP_PORT") || 80
    backend_port = opts[:backend_port] || env_int("PORT") || 4000
    backend_host = opts[:backend_host] || "127.0.0.1"

    prepared_dir =
      Path.join(System.tmp_dir!(), "devide-lan-http-edge-#{System.unique_integer([:positive])}")

    paths =
      DevIDE.Setup.InsecureHttpEdge.write_units!(prepared_dir,
        listen_port: listen_port,
        backend_host: backend_host,
        backend_port: backend_port,
        proxyd_path: proxyd
      )

    Mix.shell().info("""
    DevIDE INSECURE LAN HTTP edge units are ready.

    Files:
      socket:  #{paths.socket_path}
      service: #{paths.service_path}

    Proxy:
      :#{listen_port} -> #{backend_host}:#{backend_port}

    WARNING: this exposes DevIDE over plain HTTP on the LAN.
    """)

    if fix? do
      install_or_print(paths, unit_dir, enable?, listen_port)
    else
      print_manual_install(paths, unit_dir, enable?, listen_port)
    end
  end

  defp missing_proxyd! do
    Mix.raise("""
    systemd-socket-proxyd was not found.

    On systemd Linux hosts it is usually installed with systemd itself.
    Arch package: systemd
    """)
  end

  defp install_or_print(paths, unit_dir, enable?, listen_port) do
    commands = install_commands(paths, unit_dir, enable?, listen_port)

    case run_commands_noninteractive(commands) do
      :ok ->
        Mix.shell().info("Installed and activated DevIDE INSECURE LAN HTTP edge.")

      {:error, failed_command, output} ->
        Mix.shell().info("Could not apply privileged HTTP edge setup non-interactively.")
        Mix.shell().info("Run these commands in an interactive shell:\n")
        print_commands(commands)
        Mix.shell().info("\nFirst failed command:\n  #{Enum.join(failed_command, " ")}")

        if String.trim(output) != "" do
          Mix.shell().info("\nOutput:\n#{String.trim(output)}")
        end
    end
  end

  defp print_manual_install(paths, unit_dir, enable?, listen_port) do
    Mix.shell().info("Install with:\n")
    print_commands(install_commands(paths, unit_dir, enable?, listen_port))
  end

  defp install_commands(paths, unit_dir, enable?, listen_port) do
    commands = [
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.socket_path,
        Path.join(unit_dir, DevIDE.Setup.InsecureHttpEdge.socket_unit())
      ],
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.service_path,
        Path.join(unit_dir, DevIDE.Setup.InsecureHttpEdge.service_unit())
      ],
      ["sudo", "systemctl", "daemon-reload"]
    ]

    commands =
      if enable? do
        commands ++
          [["sudo", "systemctl", "enable", "--now", DevIDE.Setup.InsecureHttpEdge.socket_unit()]]
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
