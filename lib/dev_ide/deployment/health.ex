defmodule DevIDE.Deployment.Health do
  @moduledoc """
  Runtime health checks for the devbox release handoff.

  This is intentionally focused on deploy wiring, not application domain health:
  the checks verify the active Unix socket, the `/run/devide/current.sock` symlink,
  the Caddy app upstream for `PHX_HOST`, and deploy drift status.
  """

  alias DevIDE.Deployment.{Drift, LastDeploy, Registry}

  @current_symlink "/run/devide/current.sock"
  @expected_caddy_dials [
    "unix//run/devide/current.sock",
    "127.0.0.1:4000"
  ]

  @spec status(keyword()) :: %{ok: boolean(), checks: map(), version: String.t()}
  def status(opts \\ []) do
    version = Keyword.get_lazy(opts, :version, &Registry.version/0)
    socket_path = Keyword.get_lazy(opts, :socket_path, &Registry.socket_path/0)
    current_target = Keyword.get_lazy(opts, :current_target, &current_target/0)
    caddy_config = Keyword.get_lazy(opts, :caddy_config, &fetch_caddy_config/0)
    host = Keyword.get(opts, :host) || System.get_env("PHX_HOST") || default_host()
    branch = Keyword.get(opts, :branch) || Drift.branch()
    remote = remote_head(opts, branch)
    drift = Drift.assess(version, remote, branch)
    last_deploy = LastDeploy.summary(Keyword.merge(opts, deployed: version, remote_head: remote))

    checks = %{
      socket_exists: socket_path && File.exists?(socket_path),
      current_socket_points_to_instance: current_target == socket_path,
      caddy_devide_upstream: caddy_upstream_check(caddy_config, host),
      deploy_revision_current: drift == :current,
      deploy_pipeline_ok: last_deploy.pipeline != :failed
    }

    %{
      ok: Enum.all?(checks, fn {_name, result} -> check_ok?(result) end),
      version: version,
      socket_path: socket_path,
      current_socket: current_target,
      last_deploy: last_deploy,
      checks: checks
    }
  end

  @doc "Returns the app reverse-proxy dial for the given host from a Caddy JSON config."
  @spec caddy_app_dial(map(), String.t()) :: String.t() | nil
  def caddy_app_dial(config, host) when is_map(config) and is_binary(host) do
    config
    |> get_in(["apps", "http", "servers", "srv0", "routes"])
    |> List.wrap()
    |> Enum.find_value(fn route ->
      if host_route?(route, host), do: find_app_dial(route), else: nil
    end)
  end

  def caddy_app_dial(_, _), do: nil

  defp caddy_upstream_check({:ok, config}, host) do
    dial = caddy_app_dial(config, host)
    %{ok: dial in @expected_caddy_dials, expected: @expected_caddy_dials, actual: dial}
  end

  defp caddy_upstream_check({:error, reason}, _host) do
    %{ok: false, expected: @expected_caddy_dials, actual: nil, error: inspect(reason)}
  end

  defp check_ok?(%{ok: ok}), do: ok == true
  defp check_ok?(value), do: value == true

  defp host_route?(route, host) do
    route
    |> Map.get("match", [])
    |> Enum.any?(fn matcher -> host in Map.get(matcher, "host", []) end)
  end

  defp find_app_dial(%{"handler" => "reverse_proxy", "upstreams" => upstreams} = proxy) do
    if get_in(proxy, ["rewrite", "uri"]) == "/oauth2/auth" do
      nil
    else
      upstreams |> List.wrap() |> Enum.find_value(&Map.get(&1, "dial"))
    end
  end

  defp find_app_dial(%{} = map) do
    map
    |> Enum.reject(fn {key, _value} -> key == "handle_response" end)
    |> Enum.find_value(fn {_key, value} -> find_app_dial(value) end)
  end

  defp find_app_dial(list) when is_list(list), do: Enum.find_value(list, &find_app_dial/1)
  defp find_app_dial(_), do: nil

  defp current_target do
    File.read_link(@current_symlink)
    |> case do
      {:ok, target} -> target
      _ -> nil
    end
  end

  defp fetch_caddy_config do
    case Req.get("http://localhost:2019/config/", receive_timeout: 1_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp remote_head(opts, branch) do
    case Keyword.fetch(opts, :remote_head) do
      {:ok, remote_head} -> remote_head
      :error -> Drift.remote_head(branch: branch)
    end
  end

  defp default_host do
    :dev_ide
    |> Application.get_env(:deployment, [])
    |> Keyword.get(:default_host, "devide.devbox.milcgroup.com")
  end
end
