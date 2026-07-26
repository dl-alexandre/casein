defmodule Casein.Setup.LanRuntime do
  @moduledoc """
  Runtime helpers behind `mix casein.lan.*`.
  """

  alias Casein.Setup.InsecureHttpEdge
  alias Casein.Setup.LanEdge
  alias Casein.Setup.LanService
  alias Casein.Setup.LocalDomain

  @default_workspaces_root "/tmp/casein_workspaces"
  @status_timeout 4_000

  def config(opts \\ []) when is_list(opts) do
    user = Keyword.get(opts, :user) || target_user()
    home = Keyword.get(opts, :home) || home_dir(user)

    %{
      backend_host: Keyword.get(opts, :backend_host, "127.0.0.1"),
      backend_port: Keyword.get(opts, :backend_port) || env_int("PORT") || 4000,
      build_path: Keyword.get(opts, :build_path) || default_build_path(user),
      firewall?: Keyword.get(opts, :firewall?, true),
      group: Keyword.get(opts, :group) || primary_group(user),
      home: home,
      home_workspace_path:
        Keyword.get(opts, :home_workspace_path) || System.get_env("CASEIN_HOME_WORKSPACE_PATH") ||
          home,
      lan_host:
        Keyword.get(opts, :lan_host) || System.get_env("CASEIN_LAN_HOST") ||
          LocalDomain.mdns_hostname(),
      lan_ip: Keyword.get(opts, :lan_ip) || LocalDomain.default_ip(),
      listen_port:
        Keyword.get(opts, :listen_port) || env_int("CASEIN_LAN_INSECURE_HTTP_PORT") || 80,
      mise_path: Keyword.get(opts, :mise_path) || System.find_executable("mise"),
      proxyd_path: Keyword.get(opts, :proxyd_path) || InsecureHttpEdge.proxyd_path(),
      timeout_seconds: Keyword.get(opts, :timeout_seconds, 30),
      unit_dir: Keyword.get(opts, :unit_dir) || LanService.unit_dir(),
      user: user,
      workdir: Keyword.get(opts, :workdir, File.cwd!()) |> Path.expand(),
      workspace:
        Keyword.get(opts, :workspace) || System.get_env("CASEIN_DEFAULT_WORKSPACE") || "home",
      workspaces_root:
        Keyword.get(opts, :workspaces_root) || System.get_env("CASEIN_WORKSPACES_ROOT") ||
          @default_workspaces_root
    }
  end

  def validate(%{} = config) do
    cond do
      is_nil(config.mise_path) ->
        {:error, "mise was not found on PATH; install mise or pass --mise-path"}

      is_nil(config.proxyd_path) ->
        {:error, "systemd-socket-proxyd was not found; install systemd or pass --proxyd-path"}

      unsafe_workspace_name?(config.workspace) ->
        {:error, "invalid workspace name #{inspect(config.workspace)}"}

      unsafe_home_workspace_path?(config.home_workspace_path) ->
        {:error, "invalid home workspace path #{inspect(config.home_workspace_path)}"}

      true ->
        :ok
    end
  end

  def prepare_units!(%{} = config) do
    dir = Path.join(System.tmp_dir!(), "casein-lan-#{System.unique_integer([:positive])}")

    service_paths =
      LanService.write_unit!(dir,
        backend_port: config.backend_port,
        build_path: config.build_path,
        group: config.group,
        home: config.home,
        home_workspace_path: config.home_workspace_path,
        lan_host: config.lan_host,
        listen_port: config.listen_port,
        mise_path: config.mise_path,
        user: config.user,
        workdir: config.workdir,
        workspace: config.workspace,
        workspaces_root: config.workspaces_root
      )

    edge_paths =
      InsecureHttpEdge.write_units!(dir,
        backend_host: config.backend_host,
        backend_port: config.backend_port,
        listen_port: config.listen_port,
        proxyd_path: config.proxyd_path || missing_proxyd!()
      )

    %{
      backend_service_path: service_paths.service_path,
      edge_service_path: edge_paths.service_path,
      socket_path: edge_paths.socket_path
    }
  end

  def install_commands(paths, %{} = config) do
    [
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.backend_service_path,
        Path.join(config.unit_dir, LanService.service_unit())
      ],
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.socket_path,
        Path.join(config.unit_dir, InsecureHttpEdge.socket_unit())
      ],
      [
        "sudo",
        "install",
        "-m",
        "0644",
        paths.edge_service_path,
        Path.join(config.unit_dir, InsecureHttpEdge.service_unit())
      ]
    ]
    |> Kernel.++([
      ["sudo", "systemctl", "daemon-reload"],
      ["sudo", "systemctl", "enable", LanService.service_unit()],
      ["sudo", "systemctl", "restart", LanService.service_unit()],
      ["sudo", "systemctl", "enable", InsecureHttpEdge.socket_unit()],
      ["sudo", "systemctl", "restart", InsecureHttpEdge.socket_unit()]
    ])
    |> Kernel.++(firewall_commands(config))
  end

  def down_commands(%{} = _config) do
    [
      systemctl_best_effort("disable --now #{InsecureHttpEdge.socket_unit()}"),
      systemctl_best_effort("stop #{InsecureHttpEdge.service_unit()}"),
      systemctl_best_effort("disable --now #{LanService.service_unit()}"),
      systemctl_best_effort("reset-failed #{InsecureHttpEdge.service_unit()}"),
      systemctl_best_effort("reset-failed #{LanService.service_unit()}")
    ]
  end

  # Commands are built as argv lists by Casein setup code, not shell input.
  # sobelow_skip ["CI.System"]
  def run_commands_noninteractive(commands) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      command = sudo_noninteractive(command)

      case System.cmd(List.first(command), tl(command), stderr_to_stdout: true) do
        {_out, 0} -> {:cont, :ok}
        {out, _status} -> {:halt, {:error, command, out}}
      end
    end)
  end

  def status(%{} = config) do
    canonical_probe = http_probe(config.lan_host, config.listen_port, @status_timeout)
    ip_probe = http_probe(config.lan_ip, config.listen_port, @status_timeout)
    backend_service? = LanEdge.systemd_unit_active?(LanService.service_unit())
    backend_listener? = InsecureHttpEdge.listener_open?(config.backend_port)
    edge_socket? = LanEdge.systemd_unit_active?(InsecureHttpEdge.socket_unit())
    edge_listener? = InsecureHttpEdge.listener_open?(config.listen_port)

    checks = [
      {:backend_service, backend_service?,
       unit_message(LanService.service_unit(), backend_service?)},
      {:backend_listener, backend_listener?,
       listener_message("#{config.backend_host}:#{config.backend_port}", backend_listener?)},
      {:edge_socket, edge_socket?, unit_message(InsecureHttpEdge.socket_unit(), edge_socket?)},
      {:edge_listener, edge_listener?,
       listener_message("LAN edge :#{config.listen_port}", edge_listener?)},
      {:canonical_http, probe_ok?(canonical_probe),
       probe_message(config.lan_host, canonical_probe)}
    ]

    ready? = Enum.all?(checks, fn {_key, ok?, _message} -> ok? end)

    manual_backend? =
      manual_backend?(backend_service?, backend_listener?, canonical_probe, ip_probe)

    %{
      backend_url: "http://#{config.backend_host}:#{config.backend_port}/",
      canonical_url: url_for(config.lan_host, config.listen_port),
      checks: checks,
      config: config,
      ip_probe: ip_probe,
      ip_url: url_for(config.lan_ip, config.listen_port),
      manual_backend?: manual_backend?,
      ready?: ready?
    }
  end

  def wait_until_ready(%{} = config, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    wait_until_ready(config, deadline, nil)
  end

  def print_status(%{} = status, shell) do
    status
    |> status_lines()
    |> Enum.each(&shell.info/1)
  end

  def status_lines(%{} = status) do
    [
      "Casein Managed LAN status",
      "",
      readiness_line(status),
      "  INFO      backend #{status.backend_url}",
      "  INFO      IP fallback #{status.ip_url}",
      manual_backend_line(status),
      check_lines(status),
      "  #{status_label(probe_ok?(status.ip_probe))}        #{probe_message(status.config.lan_ip, status.ip_probe)}"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp readiness_line(%{ready?: true, canonical_url: canonical_url}) do
    "  MANAGED READY     #{canonical_url}"
  end

  defp readiness_line(%{canonical_url: canonical_url}) do
    "  MANAGED NOT READY #{canonical_url}"
  end

  defp manual_backend_line(%{manual_backend?: true}) do
    "  INFO      manual backend detected; URL works but casein-lan.service is inactive"
  end

  defp manual_backend_line(_status), do: nil

  defp check_lines(status) do
    Enum.map(status.checks, fn {_key, ok?, message} ->
      "  #{status_label(ok?)}        #{message}"
    end)
  end

  def sudo_hint(commands) do
    command_text =
      commands
      |> Enum.map_join("\n  ", &Enum.join(&1, " "))

    """
    Administrator access is needed to install or control the LAN systemd units.

    Run this once in your terminal, then rerun the Casein LAN command:

      sudo -v

    Privileged commands that will be applied:

      #{command_text}
    """
  end

  defp wait_until_ready(config, deadline, last_status) do
    status = status(config)

    cond do
      status.ready? ->
        status

      System.monotonic_time(:millisecond) >= deadline ->
        status

      true ->
        Process.sleep(500)
        wait_until_ready(config, deadline, status)
    end
  rescue
    _ ->
      if System.monotonic_time(:millisecond) >= deadline do
        last_status || status(config)
      else
        Process.sleep(500)
        wait_until_ready(config, deadline, last_status)
      end
  end

  defp http_probe(host, port, timeout_ms) do
    with {:ok, socket} <-
           :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], timeout_ms),
         :ok <-
           :gen_tcp.send(
             socket,
             "HEAD / HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\nUser-Agent: Casein-LAN\r\n\r\n"
           ),
         {:ok, response} <- :gen_tcp.recv(socket, 0, timeout_ms) do
      :gen_tcp.close(socket)
      {:ok, parse_http_status(response)}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  rescue
    error -> {:error, error}
  end

  defp parse_http_status("HTTP/" <> rest) do
    rest
    |> String.split([" ", "\r\n"], trim: true)
    |> Enum.at(1)
    |> case do
      nil -> :unknown
      status -> String.to_integer(status)
    end
  rescue
    _ -> :unknown
  end

  defp parse_http_status(_response), do: :unknown

  defp probe_ok?({:ok, status}) when is_integer(status) and status in 200..399, do: true
  defp probe_ok?(_probe), do: false

  defp probe_message(host, {:ok, status}) when is_integer(status) do
    "http://#{host}/ returns HTTP #{status}"
  end

  defp probe_message(host, {:ok, status}) do
    "http://#{host}/ returned #{inspect(status)}"
  end

  defp probe_message(host, {:error, reason}) do
    "http://#{host}/ failed: #{format_reason(reason)}"
  end

  defp manual_backend?(false, true, canonical_probe, ip_probe) do
    probe_ok?(canonical_probe) or probe_ok?(ip_probe)
  end

  defp manual_backend?(_backend_service?, _backend_listener?, _canonical_probe, _ip_probe),
    do: false

  defp unit_message(unit, true), do: "#{unit} is active"
  defp unit_message(unit, false), do: "#{unit} is inactive"

  defp listener_message(label, true), do: "#{label} accepts TCP"
  defp listener_message(label, false), do: "#{label} is not accepting TCP"

  defp format_reason(:timeout), do: "timeout"
  defp format_reason(:nxdomain), do: "name does not resolve"
  defp format_reason(:econnrefused), do: "connection refused"
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp status_label(true), do: "OK   "
  defp status_label(false), do: "WARN "

  defp url_for(host, 80), do: "http://#{host}/"
  defp url_for(host, port), do: "http://#{host}:#{port}/"

  defp firewall_commands(%{firewall?: false}), do: []

  defp firewall_commands(%{listen_port: port}) do
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

  defp systemctl_best_effort(command) do
    ["sudo", "sh", "-c", "systemctl #{command} >/dev/null 2>&1 || true"]
  end

  defp missing_proxyd! do
    raise """
    systemd-socket-proxyd was not found.

    On systemd Linux hosts it is usually installed with systemd itself.
    Arch package: systemd
    """
  end

  defp sudo_noninteractive(["sudo" | rest]), do: ["sudo", "-n" | rest]
  defp sudo_noninteractive(command), do: command

  defp target_user do
    cond do
      System.get_env("SUDO_USER") not in [nil, ""] ->
        System.get_env("SUDO_USER")

      System.get_env("USER") not in [nil, ""] ->
        System.get_env("USER")

      true ->
        case System.cmd("id", ["-un"], stderr_to_stdout: true) do
          {user, 0} -> String.trim(user)
          _ -> "root"
        end
    end
  end

  defp primary_group(user) do
    case System.cmd("id", ["-gn", user], stderr_to_stdout: true) do
      {group, 0} -> String.trim(group)
      _ -> user
    end
  end

  # getent path comes from System.find_executable/1 and user is an argv value.
  # sobelow_skip ["CI.System"]
  defp home_dir(user) do
    with getent when is_binary(getent) <- System.find_executable("getent"),
         {passwd, 0} <- System.cmd(getent, ["passwd", user], stderr_to_stdout: true),
         [_name, _passwd, _uid, _gid, _gecos, home | _rest] <-
           passwd |> String.trim() |> String.split(":") do
      home
    else
      _ ->
        if user == System.get_env("USER") do
          System.user_home!()
        else
          "/home/#{user}"
        end
    end
  end

  defp default_build_path(user) do
    Path.join(System.tmp_dir!(), "casein-lan-build-#{user}")
  end

  defp env_int(name) do
    case System.get_env(name) do
      nil -> nil
      value -> String.to_integer(value)
    end
  rescue
    ArgumentError -> nil
  end

  defp unsafe_workspace_name?(name) do
    name in ["", ".", ".."] or String.contains?(name, "/")
  end

  defp unsafe_home_workspace_path?(path) when is_binary(path) do
    expanded = Path.expand(path)

    Path.type(path) != :absolute or String.contains?(path, ["/../", "/./"]) or
      String.ends_with?(path, ["/..", "/."]) or protected_path?(expanded)
  end

  defp unsafe_home_workspace_path?(_path), do: true

  defp protected_path?(path) do
    protected = [
      "/",
      "/bin",
      "/boot",
      "/dev",
      "/etc",
      "/lib",
      "/lib64",
      "/proc",
      "/root",
      "/run",
      "/sbin",
      "/sys",
      "/usr"
    ]

    Enum.any?(protected, fn root -> path == root or String.starts_with?(path, root <> "/") end)
  end
end
