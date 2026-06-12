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

          case File.read(path) do
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

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    id = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    dir = instance_dir()

    data = %{
      "id" => id,
      "version" => version(),
      "pid" => System.pid(),
      "http_port" => System.get_env("PORT", "4000"),
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "draining" => false
    }

    file_path = Path.join(dir, "#{id}.json")
    write_atomic(file_path, data)

    {:ok, %{id: id, file_path: file_path, data: data}}
  end

  @impl true
  def handle_call(:instance_id, _from, state), do: {:reply, state.id, state}
  def handle_call(:http_port, _from, state), do: {:reply, state.data["http_port"], state}

  def handle_call(:mark_draining, _from, state) do
    new_data = Map.put(state.data, "draining", true)
    write_atomic(state.file_path, new_data)
    {:reply, :ok, %{state | data: new_data}}
  end

  @impl true
  def terminate(_reason, state) do
    File.rm(state.file_path)
    :ok
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp write_atomic(path, data) do
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(data))
    File.rename!(tmp, path)
  end

  defp instance_dir do
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
