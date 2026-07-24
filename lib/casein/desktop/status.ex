defmodule Casein.Desktop.Status do
  @moduledoc """
  Publishes the desktop host status contract (`runtime.json`).

  Started only in the desktop profile, ordered after the endpoint so the
  bound port is known (`PORT=0` requests an ephemeral port). The file is
  written atomically (tmp file + rename in the same directory) once the
  endpoint is up and removed on graceful shutdown. Crashes leave it behind
  by design — hosts must treat a file whose `pid` is not alive as stale.
  See `docs/desktop/platform_architecture.md`, "Status contract".

  The domain boundary cannot reference `CaseinWeb`, so the endpoint's bound
  port arrives through the injected `:port_resolver` (or a literal `:port`).
  """

  use GenServer

  alias Casein.Desktop.Runtime
  alias Casein.Release.Metadata

  @schema 1

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Schema version of the runtime.json contract."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema

  @doc "The payload most recently published, or nil when not running."
  @spec current(GenServer.server()) :: map() | nil
  def current(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> nil
      pid_or_name -> GenServer.call(pid_or_name, :current)
    end
  end

  @doc "Build the runtime.json payload for a bound port."
  @spec payload(:inet.port_number()) :: map()
  def payload(port) when is_integer(port) do
    {version, revision} = release_identity()

    %{
      "schema" => @schema,
      "status" => "ready",
      "port" => port,
      "base_url" => "http://127.0.0.1:#{port}",
      "pid" => String.to_integer(System.pid()),
      "version" => version,
      "revision" => revision,
      "started_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  @doc """
  Atomically publish `payload` at `path`: write a tmp file in the same
  directory, then rename over the target so hosts never read a torn file.
  """
  @spec write!(Path.t(), map()) :: :ok
  # The status path is operator/profile config, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def write!(path, %{} = payload) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp." <> Integer.to_string(:erlang.unique_integer([:positive]))
    File.write!(tmp, Jason.encode!(payload, pretty: true) <> "\n")
    File.rename!(tmp, path)
    :ok
  end

  @doc "Read and decode a published status file, rejecting unknown schemas."
  @spec read(Path.t()) :: {:ok, map()} | {:error, term()}
  # The status path is operator/profile config, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def read(path) do
    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body) do
      case decoded do
        %{"schema" => @schema} -> {:ok, decoded}
        %{"schema" => other} -> {:error, {:unsupported_schema, other}}
        _ -> {:error, :missing_schema}
      end
    else
      {:error, %Jason.DecodeError{} = err} -> {:error, {:invalid_json, err}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Remove a published status file; a missing file is fine."
  @spec clear(Path.t()) :: :ok | {:error, File.posix()}
  # The status path is operator/profile config, not web input.
  # sobelow_skip ["Traversal.FileModule"]
  def clear(path \\ Runtime.status_path()) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    path = Keyword.get(opts, :path) || Runtime.status_path()

    case resolve_port(opts) do
      {:ok, port} ->
        payload = payload(port)
        write!(path, payload)
        {:ok, %{path: path, payload: payload}}

      {:error, reason} ->
        {:stop, {:desktop_status_port_unresolved, reason}}
    end
  end

  @impl true
  def handle_call(:current, _from, state) do
    {:reply, state.payload, state}
  end

  @impl true
  def terminate(_reason, %{path: path}) do
    _ = clear(path)
    :ok
  end

  defp resolve_port(opts) do
    case Keyword.fetch(opts, :port) do
      {:ok, port} when is_integer(port) ->
        {:ok, port}

      :error ->
        # Shape of Phoenix.Endpoint.server_info/1.
        case Keyword.fetch!(opts, :port_resolver).() do
          {:ok, {_ip, port}} when is_integer(port) -> {:ok, port}
          other -> {:error, other}
        end
    end
  end

  defp release_identity do
    case Metadata.load_current() do
      {:ok, %{version: version, revision: revision}, _root} ->
        {version, revision}

      _ ->
        {to_string(Application.spec(:casein, :vsn) || "0.0.0"), "unknown"}
    end
  end
end
