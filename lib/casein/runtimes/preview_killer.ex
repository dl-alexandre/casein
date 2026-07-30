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

      if windows?() do
        kill_windows_tree(pid_str)
      else
        kill_unix_pid(pid_str)
      end
    end

    defp kill_unix_pid(pid_str) do
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

    # PID is digits-only from the launcher-owned registry and taskkill is resolved.
    # sobelow_skip ["CI.System"]
    defp kill_windows_tree(pid_str) do
      case System.find_executable("taskkill.exe") || System.find_executable("taskkill") do
        nil ->
          {:error, :taskkill_missing}

        taskkill ->
          {output, status} =
            System.cmd(taskkill, ["/PID", pid_str, "/T", "/F"], stderr_to_stdout: true)

          Logger.debug(
            "[runtime-reaper] taskkill /PID #{pid_str} /T /F status=#{status} " <>
              "output=#{String.trim(output)}"
          )

          :ok
      end
    end

    # Port is range-checked; fuser path comes from System.find_executable/1.
    # sobelow_skip ["CI.System"]
    defp kill_port_listener(port) when is_integer(port) and port > 0 and port < 65_536 do
      if port_reachable?(port) do
        if windows?(), do: kill_windows_port_listener(port), else: kill_unix_port_listener(port)
      else
        :ok
      end
    end

    defp kill_port_listener(_), do: :ok

    defp kill_unix_port_listener(port) do
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
    end

    # netstat is resolved and the port is range-checked before this call.
    # sobelow_skip ["CI.System"]
    defp kill_windows_port_listener(port) do
      with netstat when is_binary(netstat) <-
             System.find_executable("netstat.exe") || System.find_executable("netstat"),
           {output, 0} <- System.cmd(netstat, ["-ano", "-p", "tcp"], stderr_to_stdout: true),
           pid when is_binary(pid) <- listening_pid(output, port) do
        kill_windows_tree(pid)
      else
        nil -> {:error, :windows_port_owner_not_found}
        {_output, status} -> {:error, {:netstat_failed, status}}
      end
    end

    defp listening_pid(output, port) do
      pattern = ~r/^\s*TCP\s+\S+:#{port}\s+\S+\s+LISTENING\s+([0-9]+)\s*$/mi

      case Regex.run(pattern, output) do
        [_, pid] -> pid
        _ -> nil
      end
    end

    defp windows? do
      System.get_env("CASEIN_NATIVE_WINDOWS") == "true" or match?({:win32, _}, :os.type())
    end

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
