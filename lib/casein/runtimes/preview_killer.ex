defmodule Casein.Runtimes.PreviewKiller do
  @moduledoc """
  Best-effort teardown for runtime-owned preview-server OS processes.

  Reads the launcher registry under `.casein-preview/instances/` and signals
  recorded pids, then falls back to killing any process still listening on the
  preview port.
  """

  require Logger

  @spec kill(map()) :: :ok | {:error, term()}
  def kill(server) when is_map(server), do: impl().kill(server)
  def kill(_), do: :ok

  defp impl do
    Application.get_env(:casein, :runtime_preview_killer, __MODULE__.Default)
  end

  defmodule Default do
    @moduledoc false

    @behaviour Casein.Runtimes.PreviewKiller.Behaviour

    @impl true
    def kill(server) when is_map(server) do
      _ = kill_registry_pids(server)
      kill_port_listener(Map.get(server, "port"))
    end

    # cwd and runtime_id come from runtime metadata registered by PreviewLauncher.
    # sobelow_skip ["Traversal.FileModule"]
    defp kill_registry_pids(server) do
      runtime_id = Map.get(server, "runtime_id")
      cwd = Map.get(server, "cwd")
      env = Map.get(server, "env") || %{}

      preview_home =
        Map.get(env, "CASEIN_PREVIEW_HOME") || Map.get(env, :CASEIN_PREVIEW_HOME) ||
          (is_binary(cwd) && Path.join(cwd, ".casein-preview"))

      if is_binary(runtime_id) and
           Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,255}\z/, runtime_id) and
           is_binary(preview_home) and preview_home != "" do
        registry = Path.join([preview_home, "instances", "#{runtime_id}.json"])

        case File.read(registry) do
          {:ok, body} ->
            _ = kill_registry_json(body)
            _ = File.rm(registry)
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "[runtime-reaper] could not read preview registry #{registry}: #{inspect(reason)}"
            )

            :ok
        end
      else
        :ok
      end
    end

    defp kill_registry_json(body) when is_binary(body) do
      with {:ok, %{} = map} <- Jason.decode(body) do
        kill_os_pid(map["pid"])
        kill_os_pid(map["proxy_pid"])
        :ok
      else
        _ -> :ok
      end
    end

    defp kill_os_pid(pid) when pid in [nil, ""], do: :ok

    defp kill_os_pid(pid) do
      pid_str = to_string(pid)

      case System.cmd("kill", ["-TERM", pid_str], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {output, status} ->
          Logger.debug(
            "[runtime-reaper] kill -TERM #{pid_str} status=#{status} output=#{String.trim(output)}"
          )

          _ = System.cmd("kill", ["-KILL", pid_str], stderr_to_stdout: true)
          :ok
      end
    end

    # Port is range-checked; fuser path comes from System.find_executable/1.
    # sobelow_skip ["CI.System"]
    defp kill_port_listener(port) when is_integer(port) and port > 0 and port < 65_536 do
      if port_reachable?(port) do
        case System.find_executable("fuser") do
          nil ->
            {:error, :fuser_missing}

          fuser ->
            {output, status} =
              System.cmd(fuser, ["-k", "-TERM", "#{port}/tcp"], stderr_to_stdout: true)

            Logger.debug(
              "[runtime-reaper] fuser -k #{port}/tcp status=#{status} output=#{String.trim(output)}"
            )

            :ok
        end
      else
        :ok
      end
    end

    defp kill_port_listener(_), do: :ok

    defp port_reachable?(port) do
      case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 250) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        {:error, _} ->
          false
      end
    end
  end

  defmodule Behaviour do
    @moduledoc false
    @callback kill(map()) :: :ok | {:error, term()}
  end
end
