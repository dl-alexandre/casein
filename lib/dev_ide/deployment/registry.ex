defmodule DevIDE.Deployment.Registry do
  @moduledoc """
  Tracks this running process instance by writing a JSON heartbeat file into a
  well-known directory (`/run/devide/instances` or `/tmp/devide/instances`).
  Other processes (drain controller, health checks) can call `list_instances/0`
  to discover every live instance on the same host.  The file is removed
  best-effort on `terminate/2`.
  """

  use GenServer

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
    write_atomic(file_path, data)

    if socket_path, do: maybe_init_current_symlink(socket_path)
    DevIDE.Deployment.Drift.check_async()

    {:ok, %{id: id, file_path: file_path, data: data}}
  end

  @impl true
  def handle_call(:instance_id, _from, state), do: {:reply, state.id, state}
  def handle_call(:http_port, _from, state), do: {:reply, state.data["http_port"], state}
  def handle_call(:socket_path, _from, state), do: {:reply, state.data["socket_path"], state}

  def handle_call(:mark_draining, _from, state) do
    new_data = Map.put(state.data, "draining", true)
    write_atomic(state.file_path, new_data)
    {:reply, :ok, %{state | data: new_data}}
  end

  @impl true
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

  @spec version() :: String.t()
  def version do
    System.get_env("DEVIDE_GIT_REVISION") ||
      to_string(Application.spec(:dev_ide, :vsn))
  rescue
    _ -> "dev"
  end
end
