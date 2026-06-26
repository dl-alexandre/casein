defmodule DevIDE.Setup.LanEdge do
  @moduledoc """
  Helpers for DevIDE's optional LAN HTTPS edge.

  The edge is a systemd socket plus `systemd-socket-proxyd` service that listens
  on privileged port 443 and forwards raw TLS to DevIDE's unprivileged LAN HTTPS
  listener. DevIDE still owns certificate termination on port 4443.
  """

  @socket_unit "devide-lan-edge.socket"
  @service_unit "devide-lan-edge.service"
  @unit_dir "/etc/systemd/system"

  def socket_unit, do: @socket_unit
  def service_unit, do: @service_unit
  def unit_dir, do: @unit_dir

  def proxyd_path do
    System.find_executable("systemd-socket-proxyd") ||
      Enum.find(
        ["/usr/lib/systemd/systemd-socket-proxyd", "/lib/systemd/systemd-socket-proxyd"],
        &File.exists?/1
      )
  end

  def socket_unit_text(listen_port) do
    """
    [Unit]
    Description=DevIDE LAN HTTPS edge socket
    Documentation=https://github.com/dl-alexandre/dev_ide

    [Socket]
    ListenStream=#{listen_port}
    NoDelay=true

    [Install]
    WantedBy=sockets.target
    """
  end

  def service_unit_text(opts) when is_list(opts) do
    proxyd = Keyword.fetch!(opts, :proxyd_path)
    backend_host = Keyword.get(opts, :backend_host, "127.0.0.1")
    backend_port = Keyword.fetch!(opts, :backend_port)

    """
    [Unit]
    Description=DevIDE LAN HTTPS edge proxy
    Requires=#{@socket_unit}
    After=network.target

    [Service]
    ExecStart=#{proxyd} #{backend_host}:#{backend_port}
    PrivateTmp=true
    NoNewPrivileges=true
    """
  end

  # dir is the setup output directory; unit filenames are fixed constants.
  # sobelow_skip ["Traversal.FileModule"]
  def write_units!(dir, opts) when is_binary(dir) and is_list(opts) do
    File.mkdir_p!(dir)

    socket_path = Path.join(dir, @socket_unit)
    service_path = Path.join(dir, @service_unit)

    File.write!(socket_path, socket_unit_text(Keyword.fetch!(opts, :listen_port)))
    File.write!(service_path, service_unit_text(opts))

    %{socket_path: socket_path, service_path: service_path}
  end

  def listener_open?(port) do
    case System.cmd("bash", ["-lc", "timeout 2 bash -c '</dev/tcp/127.0.0.1/#{port}'"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  def systemd_unit_active?(unit) do
    case System.cmd("systemctl", ["is-active", "--quiet", unit], stderr_to_stdout: true) do
      {_out, 0} -> true
      _ -> false
    end
  rescue
    _ -> false
  end
end
