defmodule Casein.Deployment.Health do
  @moduledoc """
  Runtime health checks for the devbox release handoff.

  This is intentionally focused on deploy wiring, not application domain health:
  the checks verify the active Unix socket, the `/run/casein/current.sock` symlink,
  the Caddy app upstream for `PHX_HOST`, and deploy drift status.
  """

  alias Casein.Deployment.{Capabilities, Drift, LastDeploy, Registry}

  @current_symlink "/run/casein/current.sock"
  @expected_caddy_dials [
    "unix//run/casein/current.sock",
    "127.0.0.1:4000"
  ]

  @spec status(keyword()) :: %{ok: boolean(), checks: map(), version: String.t()}
  def status(opts \\ []) do
    capabilities = Keyword.get(opts, :capabilities, Capabilities.configured())
    version = Keyword.get_lazy(opts, :version, &Registry.version/0)
    socket_path = Keyword.get_lazy(opts, :socket_path, &Registry.socket_path/0)
    host = Keyword.get(opts, :host) || System.get_env("PHX_HOST") || default_host()

    {current_target, socket_check} =
      if :socket in capabilities do
        target = Keyword.get_lazy(opts, :current_target, &current_target/0)
        {target, target == socket_path and is_binary(socket_path)}
      else
        {nil, not_configured(:socket)}
      end

    caddy_check =
      if :reverse_proxy in capabilities do
        opts
        |> Keyword.get_lazy(:caddy_config, fn -> fetch_caddy_config(opts) end)
        |> caddy_upstream_check(host)
      else
        not_configured(:reverse_proxy)
      end

    {drift_check, remote} =
      if :deploy_drift in capabilities or :deploy_status in capabilities do
        branch = Keyword.get(opts, :branch) || Drift.branch()
        remote = remote_head(opts, branch)

        check =
          if :deploy_drift in capabilities,
            do: Drift.assess(version, remote, branch) == :current,
            else: not_configured(:deploy_drift)

        {check, remote}
      else
        {not_configured(:deploy_drift), {:error, :not_configured}}
      end

    last_deploy =
      if :deploy_status in capabilities do
        LastDeploy.summary(Keyword.merge(opts, deployed: version, remote_head: remote))
      else
        %{status: :not_configured, pipeline: :not_configured}
      end

    pipeline_check =
      if :deploy_status in capabilities,
        do: last_deploy.pipeline != :failed,
        else: not_configured(:deploy_status)

    checks = %{
      socket_exists:
        if(:socket in capabilities,
          do: is_binary(socket_path) and File.exists?(socket_path),
          else: not_configured(:socket)
        ),
      current_socket_points_to_instance: socket_check,
      caddy_casein_upstream: caddy_check,
      deploy_revision_current: drift_check,
      deploy_pipeline_ok: pipeline_check
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

  defp not_configured(capability) do
    %{ok: true, status: :not_configured, capability: capability}
  end

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

  @doc false
  def fetch_caddy_config(opts \\ []) do
    probe? =
      Keyword.get_lazy(opts, :caddy_admin_probe, fn ->
        Application.get_env(:casein, :caddy_admin_probe, true)
      end)

    if probe? do
      request = Keyword.get(opts, :caddy_request, &Req.get/2)
      sleep = Keyword.get(opts, :caddy_retry_sleep, &Process.sleep/1)

      # Req's own exponential retry is disabled so the complete probe remains
      # inside the deploy handoff budget. Three one-second attempts with
      # 100/200ms backoff tolerate the observed first-request Caddy admin stall
      # while still failing closed in at most ~3.3s.
      fetch_caddy_config(request, sleep, [100, 200])
    else
      {:error, :probe_disabled}
    end
  rescue
    error -> {:error, error}
  end

  defp fetch_caddy_config(request, sleep, backoffs) do
    result =
      request.("http://localhost:2019/config/",
        retry: false,
        # Keep the three sequential transport phases within one second total.
        # Caddy admin is localhost, so pool checkout and connect should be
        # effectively immediate; the receive phase gets the larger share.
        pool_timeout: 250,
        connect_options: [timeout: 250],
        receive_timeout: 500
      )

    case result do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} when status in 500..599 ->
        retry_caddy_config({:error, {:http_status, status}}, request, sleep, backoffs)

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        retry_caddy_config({:error, reason}, request, sleep, backoffs)
    end
  rescue
    error -> retry_caddy_config({:error, error}, request, sleep, backoffs)
  end

  defp retry_caddy_config(error, _request, _sleep, []), do: error

  defp retry_caddy_config(_error, request, sleep, [backoff | rest]) do
    sleep.(backoff)
    fetch_caddy_config(request, sleep, rest)
  end

  defp remote_head(opts, branch) do
    case Keyword.fetch(opts, :remote_head) do
      {:ok, remote_head} -> remote_head
      :error -> Drift.remote_head(branch: branch)
    end
  end

  defp default_host do
    :casein
    |> Application.get_env(:deployment, [])
    |> Keyword.get(:default_host, "localhost")
  end
end
