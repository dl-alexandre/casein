defmodule Casein.Previews.TidewaveProbe do
  @moduledoc """
  Fingerprints listening localhost ports as Tidewave endpoints.

  Runs a short `curl` probe inside the workspace execution context (host path or
  container exec) so ephemeral dev-server ports discovered by `SocketDetector`
  can be classified without manager `ports.tidewave` metadata.
  """

  require Logger

  alias Casein.HostMode
  alias Casein.Previews.Deps

  @max_probes 3
  @probe_timeout_ms 1_200

  @type fingerprint :: %{
          port: integer(),
          url: String.t(),
          mcp_url: String.t(),
          source: :probe
        }

  @doc """
  Probe `ports` for Tidewave and return fingerprint maps for matches.

  Caps work at #{@max_probes} ports. Never raises.
  """
  @spec discover(map(), [integer()]) :: [fingerprint()]
  def discover(workspace, ports) when is_map(workspace) and is_list(ports) do
    ports
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.take(@max_probes)
    |> Enum.flat_map(fn port ->
      case probe_port(workspace, port) do
        {:ok, fingerprint} -> [fingerprint]
        _ -> []
      end
    end)
  end

  def discover(_workspace, _ports), do: []

  @doc "Probe a single loopback port for `/tidewave`. Returns `{:ok, fingerprint}` or `:missing`."
  @spec probe_port(map(), integer()) :: {:ok, fingerprint()} | :missing
  def probe_port(workspace, port) when is_map(workspace) and is_integer(port) do
    with {:ok, cwd} <- host_cwd(workspace),
         {:ok, code} <- run_probe(cwd, port),
         true <- tidewave_response?(code) do
      {:ok,
       %{
         port: port,
         url: "http://127.0.0.1:#{port}/tidewave",
         mcp_url: "http://127.0.0.1:#{port}/tidewave/mcp",
         source: :probe
       }}
    else
      _ -> :missing
    end
  end

  def probe_port(_, _), do: :missing

  @doc false
  @spec tidewave_response?(integer() | String.t()) :: boolean()
  def tidewave_response?(code) when is_integer(code), do: code in 200..399

  def tidewave_response?(code) when is_binary(code) do
    case Integer.parse(String.trim(code)) do
      {value, _} -> tidewave_response?(value)
      _ -> false
    end
  end

  def tidewave_response?(_), do: false

  defp host_cwd(workspace) do
    case Deps.impl(:workspaces).safe_host_path(workspace) do
      {:ok, path} -> {:ok, path}
      _ -> {:error, :no_host_path}
    end
  end

  # sobelow_skip ["CI.System"]
  defp run_probe(cwd, port) do
    script =
      "curl -s -o /dev/null -w '%{http_code}' --max-time #{div(@probe_timeout_ms, 1000)} http://127.0.0.1:#{port}/tidewave 2>/dev/null || echo 000"

    case HostMode.prepare_local_argv(["sh", "-c", script]) do
      [cmd | args] ->
        {out, _code} =
          System.cmd(cmd, args, cd: cwd, stderr_to_stdout: true, env: [{"TERM", "dumb"}])

        {:ok, String.trim(out)}

      _ ->
        {:error, :no_argv}
    end
  rescue
    e in [ErlangError, File.Error] ->
      Logger.debug("tidewave port probe failed: #{inspect(e)}")
      {:error, :probe_failed}
  catch
    :exit, reason ->
      Logger.debug("tidewave port probe exited: #{inspect(reason)}")
      {:error, :probe_exit}
  end
end
