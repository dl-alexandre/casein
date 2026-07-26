defmodule Casein.Previews.EnvRegistry do
  @moduledoc """
  Reads ephemeral preview-environment instances written by `scripts/preview-env.sh`.

  Registry JSON files live under `<preview_home>/instances/*.json`. Each record
  tracks the allocated port, process id, and (for dev instances) Tidewave MCP
  URLs.
  """

  @type instance :: map()

  @doc "Absolute path to the preview-env state directory."
  @spec home() :: String.t()
  def home do
    Application.get_env(:casein, :preview_env_home) ||
      System.get_env("CASEIN_PREVIEW_HOME") ||
      default_home()
  end

  @doc "Directory containing one JSON file per preview environment."
  @spec instances_dir() :: String.t()
  def instances_dir, do: Path.join(home(), "instances")

  @doc "Returns all registry records, newest first. Never raises."
  @spec list_instances() :: [instance()]
  def list_instances do
    instances_dir()
    |> list_json_files()
    |> Enum.map(&read_instance/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(
      fn inst -> Map.get(inst, "started_at") || "" end,
      :desc
    )
  end

  @doc "Fetch a single instance by id, or `nil`."
  @spec get(String.t()) :: instance() | nil
  def get(id) when is_binary(id) do
    with true <- valid_instance_id?(id),
         path = Path.join(instances_dir(), "#{id}.json"),
         true <- File.regular?(path) do
      read_instance(path)
    else
      _ -> nil
    end
  end

  def get(_), do: nil

  @doc "Instances whose registry `status` is `running`."
  @spec running_instances() :: [instance()]
  def running_instances do
    Enum.filter(list_instances(), &(&1["status"] == "running"))
  end

  @doc """
  Canonical unix-socket front door for an instance, dialed by the preview
  router. `nil` for older records written before socket-fronting.
  """
  @spec socket_path(instance()) :: String.t() | nil
  def socket_path(%{"socket" => sock}) when is_binary(sock) and sock != "", do: sock
  def socket_path(_), do: nil

  @doc "Browser Tidewave UI URL for an instance map."
  @spec tidewave_url(instance()) :: String.t() | nil
  def tidewave_url(%{"tidewave_url" => url}) when is_binary(url) and url != "", do: url

  def tidewave_url(%{"port" => port}) when is_binary(port) and port != "",
    do: "http://127.0.0.1:#{port}/tidewave"

  def tidewave_url(%{"port" => port}) when is_integer(port),
    do: "http://127.0.0.1:#{port}/tidewave"

  def tidewave_url(_), do: nil

  @doc "Tidewave MCP endpoint for an instance map."
  @spec tidewave_mcp_url(instance()) :: String.t() | nil
  def tidewave_mcp_url(%{"tidewave_mcp_url" => url}) when is_binary(url) and url != "",
    do: url

  def tidewave_mcp_url(%{"port" => port}) when is_binary(port) and port != "",
    do: "http://127.0.0.1:#{port}/tidewave/mcp"

  def tidewave_mcp_url(%{"port" => port}) when is_integer(port),
    do: "http://127.0.0.1:#{port}/tidewave/mcp"

  def tidewave_mcp_url(_), do: nil

  defp default_home do
    checkout =
      Application.get_env(:casein, :preview_env_checkout_root) ||
        File.cwd!()

    Path.join(Path.expand(Path.join(checkout, "..")), ".casein-preview")
  end

  defp list_json_files(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp valid_instance_id?(id) do
    id != "" and Path.basename(id) == id and String.ends_with?(id, ".json") == false
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_instance(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
