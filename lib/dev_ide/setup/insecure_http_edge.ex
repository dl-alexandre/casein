defmodule Casein.Setup.InsecureHttpEdge do
  @moduledoc """
  Helpers for Casein's intentionally insecure LAN HTTP edge.

  The edge is a systemd socket plus `systemd-socket-proxyd` service that listens
  on privileged port 80 and forwards plain HTTP to Casein's loopback HTTP
  listener. This is useful for trusted LAN dogfooding when client certificate
  trust is more friction than the test is worth.
  """

  @socket_unit "devide-lan-http-edge.socket"
  @service_unit "devide-lan-http-edge.service"
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
    Description=Casein INSECURE LAN HTTP edge socket
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
    backend_unit = Keyword.get(opts, :backend_unit, Casein.Setup.LanService.service_unit())

    """
    [Unit]
    Description=Casein INSECURE LAN HTTP edge proxy
    Requires=#{@socket_unit}
    Requires=#{backend_unit}
    After=network.target #{backend_unit}

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

  def listener_open?(port), do: Casein.Setup.LanEdge.listener_open?(port)
end
