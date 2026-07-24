defmodule Casein.Deployment.PollerTrigger do
  @moduledoc """
  Starts the on-box auto-deploy poller (`casein-deploy.service`).

  Production expects passwordless sudo for this unit only — see
  `scripts/ensure-casein-deploy-poller.sh`.
  """

  @default_service "casein-deploy.service"
  @default_timeout_ms 10_000

  @spec trigger(keyword()) :: :ok | {:error, term()}
  def trigger(opts \\ []) do
    case Application.get_env(:casein, :deploy_poller_trigger) do
      fun when is_function(fun, 1) -> fun.(opts)
      _ -> do_trigger(opts)
    end
  end

  # Service name comes from application config (:deployment :deploy_service), not user input.
  # sobelow_skip ["CI.System"]
  defp do_trigger(opts) do
    service = Keyword.get(opts, :service, config(:deploy_service, @default_service))
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    command = systemctl_command(service)

    case System.cmd(command.executable, command.args,
           stderr_to_stdout: true,
           timeout: timeout
         ) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error, {:systemctl_failed, status, String.trim(output)}}
    end
  rescue
    error ->
      {:error, error}
  end

  defp systemctl_command(service) do
    if System.find_executable("sudo") do
      %{executable: "sudo", args: ["-n", "systemctl", "start", service]}
    else
      %{executable: System.find_executable("systemctl") || "systemctl", args: ["start", service]}
    end
  end

  defp config(key, default) do
    :casein
    |> Application.get_env(:deployment, [])
    |> Keyword.get(key, default)
  end
end
