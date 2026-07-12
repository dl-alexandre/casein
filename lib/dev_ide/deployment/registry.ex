defmodule DevIDE.Deployment.Registry do
  @moduledoc """
  Tracks this running process instance by writing a JSON heartbeat file into a
  well-known directory (`/run/devide/instances` or `/tmp/devide/instances`).
  Other processes (drain controller, health checks) can call `list_instances/0`
  to discover every live instance on the same host.  The file is removed
  best-effort on `terminate/2`.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec instance_id() :: String.t()
  def instance_id, do: GenServer.call(__MODULE__, :instance_id)

  @spec mark_draining() :: :ok
  def mark_draining, do: GenServer.call(__MODULE__, :mark_draining)

  @spec list_instances() :: [map()]
  def list_instances do
    dir = instance_dir()

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.flat_map(fn name ->
          path = Path.join(dir, name)

          # sobelow_skip ["Traversal.FileModule"]
          case :file.read_file(String.to_charlist(path)) do
            {:ok, body} ->
              case Jason.decode(body) do
                {:ok, map} -> [map]
                _ -> []
              end

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  @spec http_port() :: String.t()
  def http_port, do: GenServer.call(__MODULE__, :http_port)

  @spec socket_path() :: String.t() | nil
  def socket_path, do: GenServer.call(__MODULE__, :socket_path)

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    id = System.get_env("DEVIDE_INSTANCE_UUID") || generate_id()
    dir = instance_dir()
    socket_path = System.get_env("DEVIDE_HTTP_SOCKET")

    data = %{
      "id" => id,
      "version" => version(),
      "pid" => System.pid(),
      "http_port" => System.get_env("PORT", "4000"),
      "socket_path" => socket_path,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "draining" => false
    }

    file_path = Path.join(dir, "#{id}.json")

    # DEVIDE_INSTANCE_UUID comes from the shared env file, so a secondary boot
    # of the app under the same identity (release eval, seeds, a dev/test app
    # started with the deploy env) would overwrite the serving instance's
    # heartbeat with its own short-lived pid. The deploy's stale-record cleanup
    # then reads that dead pid, deletes the record, and the real instance never
    # receives its drain signal — it outlives every later deploy and its
    # SessionOwner fights the new instance over tmux window sizes. If another
    # live process already owns this heartbeat, run without one instead.
    case heartbeat_owner_conflict(file_path) do
      {:conflict, other_pid} ->
        Logger.warning(
          "deployment registry: #{file_path} is owned by live pid #{other_pid} " <>
            "(we are #{System.pid()}); skipping heartbeat for this secondary boot"
        )

        {:ok, %{id: id, file_path: nil, data: data}}

      :ok ->
        write_atomic(file_path, data)

        if socket_path, do: maybe_init_current_symlink(socket_path)

        if DevIDE.Deployment.Capabilities.enabled?(:deploy_drift),
          do: DevIDE.Deployment.Drift.check_async()

        if DevIDE.Deployment.Capabilities.enabled?(:deploy_status),
          do: DevIDE.Deployment.LastDeploy.check_async()

        {:ok, %{id: id, file_path: file_path, data: data}}
    end
  end

  @impl true
  def handle_call(:instance_id, _from, state), do: {:reply, state.id, state}
  def handle_call(:http_port, _from, state), do: {:reply, state.data["http_port"], state}
  def handle_call(:socket_path, _from, state), do: {:reply, state.data["socket_path"], state}

  def handle_call(:mark_draining, _from, state) do
    new_data = Map.put(state.data, "draining", true)
    if state.file_path, do: write_atomic(state.file_path, new_data)
    {:reply, :ok, %{state | data: new_data}}
  end

  @impl true
  def terminate(_reason, %{file_path: nil}), do: :ok

  def terminate(_reason, state) do
    # sobelow_skip ["Traversal.FileModule"]
    :file.delete(String.to_charlist(state.file_path))
    :ok
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # A heartbeat is owned by another process when its recorded pid is a live
  # *DevIDE* process that isn't us. Liveness and identity come from /proc (the
  # deploy target is Linux); where /proc is unavailable this degrades to today's
  # overwrite behavior rather than blocking the boot.
  #
  # The cmdline check is not paranoia: a bare `/proc/<pid>` existence test would
  # false-positive if the recorded pid died and the OS recycled that number for
  # an unrelated process — we would then refuse to write our heartbeat and run
  # invisibly to list_instances/0 (health, drift). Requiring a beam/dev_ide
  # cmdline matches the deploy script's dev_ide_release_pid_alive and confines a
  # conflict to a genuine sibling DevIDE boot under the shared instance UUID.
  #
  # The pid is digit-validated before any path use.
  # sobelow_skip ["Traversal.FileModule"]
  defp heartbeat_owner_conflict(file_path) do
    with {:ok, body} <- :file.read_file(String.to_charlist(file_path)),
         {:ok, %{"pid" => pid}} when is_binary(pid) <- Jason.decode(body),
         true <- pid =~ ~r/^\d+$/,
         true <- pid != System.pid(),
         true <- owner_alive?(pid) do
      {:conflict, pid}
    else
      _ -> :ok
    end
  end

  # Seam for tests: /proc-based identity is Linux-only and hard to fabricate
  # (you can't easily spawn an OS process whose cmdline reads as a DevIDE beam),
  # so the conflict path would otherwise be untestable off the devbox. Defaults
  # to the real check; tests inject a predicate. Mirrors Drain.stop_system/1.
  defp owner_alive?(pid) do
    case Application.get_env(:dev_ide, :deployment_owner_liveness) do
      fun when is_function(fun, 1) -> fun.(pid)
      _ -> dev_ide_process?(pid)
    end
  end

  # True when /proc/<pid>/cmdline belongs to a DevIDE beam. cmdline is
  # NUL-separated; match the same markers the deploy script keys on (a release
  # under /opt/devide/release, or a dev_ide_*@host node name).
  # sobelow_skip ["Traversal.FileModule"]
  defp dev_ide_process?(pid) do
    case File.read("/proc/#{pid}/cmdline") do
      {:ok, raw} ->
        cmdline = String.replace(raw, <<0>>, " ")
        String.contains?(cmdline, "/opt/devide/release/") or cmdline =~ ~r/dev_ide_\w+@/

      _ ->
        false
    end
  end

  @current_symlink "/run/devide/current.sock"

  # Creates /run/devide/current.sock → socket_path only when the symlink is
  # absent or points to a socket that no longer exists (handles reboots where
  # /run is tmpfs and the old symlink is gone).
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_init_current_symlink(socket_path) do
    if managed_socket_path?(socket_path) and not File.exists?(@current_symlink) do
      File.ln_s(socket_path, @current_symlink)
    end
  rescue
    _ -> :ok
  end

  defp managed_socket_path?("/run/devide/instances/" <> rest),
    do: String.ends_with?(rest, ".sock")

  defp managed_socket_path?("/tmp/devide/instances/" <> rest),
    do: String.ends_with?(rest, ".sock")

  defp managed_socket_path?(_), do: false

  # sobelow_skip ["Traversal.FileModule"]
  defp write_atomic(path, data) do
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(data))
    File.rename!(tmp, path)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp instance_dir do
    case Application.get_env(:dev_ide, :deployment_instance_dir) do
      dir when is_binary(dir) ->
        File.mkdir_p!(dir)
        dir

      _ ->
        instance_dir_default()
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp instance_dir_default do
    candidates = ["/run/devide/instances", "/tmp/devide/instances"]

    Enum.find_value(candidates, fn dir ->
      case File.mkdir_p(dir) do
        :ok -> dir
        {:error, _} -> nil
      end
    end) || System.tmp_dir!()
  end

  @doc "Delegates to `DevIDE.Deployment.Version.version/0` (kept for callers)."
  @spec version() :: String.t()
  defdelegate version, to: DevIDE.Deployment.Version
end
