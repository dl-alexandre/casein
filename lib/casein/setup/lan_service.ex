defmodule Casein.Setup.LanService do
  @moduledoc """
  Helpers for the Casein LAN backend systemd service.

  The LAN service runs the Phoenix development server as the invoking user on a
  loopback backend port. A separate privileged socket edge exposes port 80 on
  the LAN.
  """

  @service_unit "casein-lan.service"
  @unit_dir "/etc/systemd/system"

  def service_unit, do: @service_unit
  def unit_dir, do: @unit_dir

  def service_unit_text(opts) when is_list(opts) do
    user = Keyword.fetch!(opts, :user)
    group = Keyword.fetch!(opts, :group)
    workdir = Keyword.fetch!(opts, :workdir)
    home = Keyword.fetch!(opts, :home)
    mise_path = Keyword.fetch!(opts, :mise_path)
    backend_port = Keyword.fetch!(opts, :backend_port)
    build_path = Keyword.fetch!(opts, :build_path)
    lan_host = Keyword.fetch!(opts, :lan_host)
    listen_port = Keyword.fetch!(opts, :listen_port)
    workspace = Keyword.fetch!(opts, :workspace)
    home_workspace_path = Keyword.fetch!(opts, :home_workspace_path)
    workspaces_root = Keyword.fetch!(opts, :workspaces_root)

    """
    [Unit]
    Description=Casein LAN backend
    Wants=network-online.target
    After=network.target network-online.target postgresql.service

    [Service]
    Type=simple
    User=#{user}
    Group=#{group}
    WorkingDirectory=#{workdir}
    #{environment("HOME", home)}
    #{environment("MIX_ENV", "dev")}
    #{environment("MIX_BUILD_PATH", build_path)}
    #{environment("PORT", Integer.to_string(backend_port))}
    #{environment("CASEIN_LAN_INSECURE_HTTP", "true")}
    #{environment("CASEIN_LAN_INSECURE_HTTP_PORT", Integer.to_string(listen_port))}
    #{environment("CASEIN_LAN_HOST", lan_host)}
    #{environment("CASEIN_LAN_DIRECT_MODE", "true")}
    #{environment("CASEIN_LAN_FRIENDLY_PATHS", "true")}
    #{environment("CASEIN_LAN_PATH_ROOT", home_workspace_path)}
    #{environment("CASEIN_DEFAULT_WORKSPACE", workspace)}
    #{environment("CASEIN_HOME_WORKSPACE_PATH", home_workspace_path)}
    #{environment("CASEIN_WORKSPACES_ROOT", workspaces_root)}
    ExecStart=#{mise_path} exec -- mix phx.server
    Restart=on-failure
    RestartSec=2
    KillMode=process
    KillSignal=SIGINT
    TimeoutStopSec=20

    [Install]
    WantedBy=multi-user.target
    """
  end

  # dir is the setup output directory; unit filename is a fixed constant.
  # sobelow_skip ["Traversal.FileModule"]
  def write_unit!(dir, opts) when is_binary(dir) and is_list(opts) do
    File.mkdir_p!(dir)

    service_path = Path.join(dir, @service_unit)
    File.write!(service_path, service_unit_text(opts))

    %{service_path: service_path}
  end

  defp environment(key, value) do
    ~s(Environment="#{key}=#{escape_environment_value(to_string(value))}")
  end

  defp escape_environment_value(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
  end
end
