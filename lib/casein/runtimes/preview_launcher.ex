defmodule Casein.Runtimes.PreviewLauncher do
  @moduledoc """
  Starts runtime-owned preview servers from their persisted preview_server record.

  The runtime registry remains the source of truth for ownership and surface
  selection. This module consumes that record asynchronously so reporting a
  worktree does not block on migrations, asset builds, or server boot.
  """

  require Logger

  alias Casein.Runtimes
  alias Casein.Runtimes.{PreviewServer, Runtime}

  @callback start(map()) :: :ok | {:error, term()}

  @doc "Ensure the runtime preview server has a launch in progress or is already reachable."
  @spec ensure_started(Runtime.t()) :: :ok | {:error, term()}
  def ensure_started(%Runtime{} = runtime) do
    cond do
      not enabled?() ->
        :ok

      is_nil(PreviewServer.for_metadata(runtime.metadata)) ->
        {:error, :runtime_preview_server_missing}

      true ->
        do_ensure_started(runtime)
    end
  end

  def ensure_started(_), do: {:error, :invalid_runtime}

  defp do_ensure_started(%Runtime{} = runtime) do
    server = PreviewServer.for_metadata(runtime.metadata)

    cond do
      PreviewServer.owns_live_port?(server) ->
        mark(runtime, "running")

      server["status"] == "starting" ->
        :ok

      true ->
        case validate_server(server) do
          :ok ->
            :ok = mark(runtime, "starting")
            start_async(runtime.id, launch_spec(server))
            :ok

          {:error, reason} = error ->
            _ = mark(runtime, "failed", inspect_reason(reason))
            error
        end
    end
  end

  defp validate_server(server) do
    cond do
      not is_binary(server["cwd"]) or server["cwd"] == "" ->
        {:error, :runtime_preview_cwd_missing}

      not File.dir?(server["cwd"]) ->
        {:error, {:runtime_preview_cwd_not_found, server["cwd"]}}

      not is_list(server["command"]) or server["command"] == [] ->
        {:error, :runtime_preview_command_missing}

      is_nil(command_launcher_path(server["command"], server["cwd"])) ->
        {:error,
         %{
           error: :runtime_preview_launcher_missing,
           cwd: server["cwd"],
           command: server["command"]
         }}

      not is_integer(server["port"]) ->
        {:error, :runtime_preview_port_missing}

      Map.get(server["env"] || %{}, "PORT") != Integer.to_string(server["port"]) ->
        {:error, :runtime_preview_port_env_mismatch}

      true ->
        :ok
    end
  end

  defp command_launcher_path(["bash", script | _], cwd)
       when is_binary(script) and script not in ["-c", "-lc"] do
    path = if Path.type(script) == :absolute, do: script, else: Path.join(cwd, script)
    if File.regular?(path), do: path
  end

  defp command_launcher_path(["bash", shell_flag, command | _], _cwd)
       when shell_flag in ["-c", "-lc"] and is_binary(command) and command != "" do
    command
  end

  defp command_launcher_path([executable | _], _cwd) when is_binary(executable) do
    System.find_executable(executable)
  end

  defp command_launcher_path(_command, _cwd), do: nil

  defp launch_spec(server) do
    %{
      "id" => server["id"],
      "runtime_id" => server["runtime_id"],
      "cwd" => server["cwd"],
      "command" => server["command"],
      "env" => server["env"] || %{},
      "port" => server["port"],
      "url" => server["url"]
    }
  end

  defp start_async(runtime_id, spec) do
    starter = fn ->
      result = runner().start(spec)

      case Runtimes.get_runtime(runtime_id) do
        {:ok, %Runtime{} = runtime} ->
          handle_start_result(runtime, result)

        :error ->
          Logger.warning("runtime preview start finished for missing runtime #{runtime_id}")
      end
    end

    case Task.Supervisor.start_child(Casein.TaskSupervisor, starter) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "runtime preview launcher could not start task for #{runtime_id}: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp handle_start_result(%Runtime{} = runtime, :ok) do
    server = PreviewServer.for_metadata(runtime.metadata)

    if PreviewServer.owns_live_port?(server) do
      mark(runtime, "running")
    else
      mark(runtime, "starting")
    end
  end

  defp handle_start_result(%Runtime{} = runtime, {:error, reason}) do
    _ = mark(runtime, "failed", inspect_reason(reason))
    :ok
  end

  defp mark(%Runtime{} = runtime, status, failure_reason \\ nil) do
    case Runtimes.mark_preview_server(runtime, status, failure_reason) do
      {:ok, _runtime} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp enabled?, do: Application.get_env(:casein, :runtime_preview_launcher_enabled, true)

  defp runner do
    Application.get_env(
      :casein,
      :runtime_preview_runner,
      Casein.Runtimes.PreviewLauncher.SystemRunner
    )
  end

  defp inspect_reason(reason) when is_binary(reason), do: reason
  defp inspect_reason(reason), do: inspect(reason)
end

defmodule Casein.Runtimes.PreviewLauncher.SystemRunner do
  @moduledoc false

  @behaviour Casein.Runtimes.PreviewLauncher

  require Logger

  @impl true
  # executable and argv come from the internal PreviewServer adapter; System.cmd never invokes a shell.
  # sobelow_skip ["CI.System"]
  def start(%{"command" => [executable | args], "cwd" => cwd} = spec)
      when is_binary(executable) and is_binary(cwd) do
    env = env_list(Map.get(spec, "env", %{}))

    case System.cmd(executable, args, cd: cwd, env: env, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, status} ->
        Logger.warning(
          "runtime preview command failed for #{spec["runtime_id"]}: " <>
            "status=#{status} output=#{String.slice(output || "", 0, 2_000)}"
        )

        {:error, {:runtime_preview_command_failed, status}}
    end
  rescue
    error -> {:error, error}
  end

  def start(_), do: {:error, :invalid_runtime_preview_launch_spec}

  defp env_list(env) when is_map(env) do
    Enum.flat_map(env, fn
      {key, value} when is_binary(key) and is_binary(value) -> [{key, value}]
      {key, value} when is_atom(key) and is_binary(value) -> [{Atom.to_string(key), value}]
      {key, value} when is_binary(key) and is_integer(value) -> [{key, Integer.to_string(value)}]
      _ -> []
    end)
  end

  defp env_list(_), do: []
end
