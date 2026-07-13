defmodule DevIDE.Runtimes.PreviewServer do
  @moduledoc """
  Runtime-scoped preview server launch metadata.

  This is a record of intent for the preview lifecycle. It does not start a
  process; it captures the cwd, command, port, environment, and surface metadata
  a launcher needs to start the runtime's own preview server from its worktree.
  """

  alias DevIDE.Previews.EnvPorts
  alias DevIDE.Runtimes.Profile
  alias DevIDE.Workspaces.State.WorkspaceRecord

  @app_surface "app"
  @default_launcher "runtime-preview-launch.sh"
  @safe_runtime_id ~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,255}\z/

  @type t :: map()

  @spec build_for_worktree(WorkspaceRecord.t(), String.t(), String.t(), String.t(), map(), [
          integer()
        ]) ::
          {:ok, t()} | {:error, term()}
  def build_for_worktree(
        %WorkspaceRecord{} = record,
        runtime_id,
        tmux_session_id,
        worktree_path,
        attrs,
        used_ports
      )
      when is_binary(runtime_id) and is_binary(worktree_path) and is_map(attrs) do
    existing = preview_server_from_attrs(attrs)

    with {:ok, port} <- resolve_port(attrs, existing, runtime_id, used_ports) do
      cwd = Path.expand(worktree_path)

      command =
        usable_command(command_from_attrs(attrs)) ||
          existing_command_for_port(existing, port) ||
          default_command(port)

      status =
        non_empty_string(value(attrs, "preview_status")) || value(existing, "status") ||
          "provisioned"

      env =
        existing
        |> value("env")
        |> env_map()
        |> Map.merge(env_from_attrs(attrs))
        |> Map.merge(%{
          "PORT" => Integer.to_string(port),
          "DEVIDE_RUNTIME_ID" => runtime_id,
          "DEVIDE_WORKSPACE_ID" => record.external_id,
          "DEVIDE_TMUX_SESSION" => tmux_session_id,
          "DEVIDE_PREVIEW_HOME" =>
            Path.join(record.host_path || worktree_path, ".devide-preview"),
          "DEVIDE_RUNTIME_PREVIEW_SOCKET" =>
            Path.join([
              record.host_path || worktree_path,
              ".devide-preview",
              "sockets",
              runtime_socket_name(runtime_id)
            ])
        })

      server =
        %{
          "id" => "preview:#{runtime_id}:#{@app_surface}",
          "runtime_id" => runtime_id,
          "workspace_id" => record.external_id,
          "tmux_session_id" => tmux_session_id,
          "cwd" => cwd,
          "worktree_path" => cwd,
          "port" => port,
          "status" => status,
          "command" => command,
          "env" => env,
          "surface_key" => "runtime:#{runtime_id}:#{@app_surface}",
          "surface_name" => @app_surface,
          "url" => "http://localhost:#{port}",
          "source" => "runtime_preview_server"
        }

      {:ok, server}
    end
  end

  def build_for_worktree(_, _, _, _, _, _), do: {:error, :invalid_runtime_preview_server}

  @doc "Return the preview server record stored on runtime metadata, if present."
  @spec for_metadata(map()) :: t() | nil
  def for_metadata(metadata) when is_map(metadata) do
    case value(metadata, "preview_server") do
      server when is_map(server) -> server
      _ -> nil
    end
  end

  def for_metadata(_), do: nil

  @doc "Put a preview server and matching runtime profile into runtime metadata."
  @spec put_profile(map(), t()) :: map()
  def put_profile(metadata, server) when is_map(metadata) and is_map(server) do
    profile =
      metadata
      |> value("runtime_profile")
      |> profile_with_server(server)

    metadata
    |> Map.put("preview_server", server)
    |> Map.put("runtime_profile", profile)
  end

  def put_profile(metadata, _server), do: metadata

  @doc """
  Record a preview provisioning failure that does not have a launchable server.

  This keeps runtime/worktree registration independent from preview port
  allocation. Callers can surface the failure from profile metadata without
  creating an invalid preview_server record for the launcher to retry.
  """
  @spec put_unavailable(map(), String.t()) :: map()
  def put_unavailable(metadata, failure_reason) when is_map(metadata) do
    profile =
      metadata
      |> value("runtime_profile")
      |> map_or_empty()
      |> Map.put("metadata", profile_status_metadata(metadata, "failed", failure_reason))

    metadata
    |> Map.delete("preview_server")
    |> Map.delete(:preview_server)
    |> Map.put("runtime_profile", profile)
  end

  def put_unavailable(metadata, _failure_reason), do: metadata

  @doc "Update preview server status in runtime metadata."
  @spec put_status(map(), String.t(), String.t() | nil) :: map()
  def put_status(metadata, status, failure_reason \\ nil)

  def put_status(metadata, status, failure_reason) when is_map(metadata) and is_binary(status) do
    server =
      metadata
      |> for_metadata()
      |> case do
        server when is_map(server) -> server
        _ -> %{}
      end
      |> Map.put("status", status)
      |> maybe_put_failure_reason(failure_reason)

    profile =
      metadata
      |> value("runtime_profile")
      |> map_or_empty()
      |> Map.put("metadata", profile_status_metadata(metadata, status, failure_reason))

    metadata
    |> Map.put("preview_server", server)
    |> Map.put("runtime_profile", profile)
  end

  def put_status(metadata, _status, _failure_reason), do: metadata

  @doc "Extract all preview ports reserved by runtime metadata."
  @spec metadata_ports(map()) :: [integer()]
  def metadata_ports(metadata) when is_map(metadata) do
    []
    |> maybe_add_port(value(value(metadata, "preview_server") || %{}, "port"))
    |> maybe_add_profile_ports(value(metadata, "runtime_profile"))
    |> Enum.uniq()
  end

  def metadata_ports(_), do: []

  @doc "Verify that a reachable preview port belongs to this runtime's launcher registry."
  @spec owns_live_port?(t() | nil) :: boolean()
  def owns_live_port?(server) when is_map(server) do
    runtime_id = value(server, "runtime_id")
    workspace_id = value(server, "workspace_id")
    cwd = non_empty_string(value(server, "cwd"))
    port = port_value(value(server, "port"))
    env = env_map(value(server, "env"))

    preview_home =
      non_empty_string(value(env, "DEVIDE_PREVIEW_HOME")) ||
        (cwd && Path.join(cwd, ".devide-preview"))

    with true <- is_binary(runtime_id) and Regex.match?(@safe_runtime_id, runtime_id),
         true <- is_binary(cwd) and Path.type(cwd) == :absolute,
         true <- is_binary(preview_home) and Path.type(preview_home) == :absolute,
         true <- is_integer(port),
         registry_path <-
           Path.join([preview_home, "instances", runtime_id <> ".json"]),
         # registry_path ends in a regex-constrained runtime id beneath the
         # launcher-owned absolute preview home.
         # sobelow_skip ["Traversal.FileModule"]
         {:ok, body} <- File.read(registry_path),
         {:ok, registry} when is_map(registry) <- Jason.decode(body),
         true <- value(registry, "runtime_id") == runtime_id,
         true <- value(registry, "workspace_id") == workspace_id,
         true <- port_value(value(registry, "port")) == port,
         true <- value(registry, "status") == "running",
         true <- same_path?(value(registry, "checkout"), cwd),
         true <- live_os_pid?(value(registry, "pid")),
         true <- port_reachable?(port) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def owns_live_port?(_server), do: false

  defp profile_with_server(profile, server) do
    base =
      case Profile.normalize(profile) do
        {:ok, profile} when is_map(profile) -> profile
        _ -> %{}
      end

    port = value(server, "port")

    profile =
      base
      |> Map.put("name", value(base, "name") || "phoenix")
      |> Map.put("kind", value(base, "kind") || "phoenix")
      |> Map.put("command", value(server, "command"))
      |> Map.put("cwd", value(server, "cwd"))
      |> Map.put("env", Map.merge(env_map(value(base, "env")), value(server, "env") || %{}))
      |> Map.put("ports", Map.merge(port_map(value(base, "ports")), %{@app_surface => port}))
      |> Map.put("surfaces", [%{"name" => @app_surface, "port" => port}])
      |> put_profile_metadata(server)

    case Profile.normalize(profile) do
      {:ok, normalized} when is_map(normalized) -> normalized
      _ -> profile
    end
  end

  defp put_profile_metadata(profile, server) do
    metadata =
      profile
      |> value("metadata")
      |> map_or_empty()
      |> Map.merge(%{
        "preview_server_id" => value(server, "id"),
        "source" => value(server, "source")
      })

    Map.put(profile, "metadata", metadata)
  end

  defp profile_status_metadata(metadata, status, failure_reason) do
    profile_metadata =
      metadata
      |> value("runtime_profile")
      |> value("metadata")
      |> map_or_empty()
      |> Map.put("preview_status", status)

    if is_binary(failure_reason) and failure_reason != "" do
      Map.put(profile_metadata, "preview_failure_reason", failure_reason)
    else
      Map.delete(profile_metadata, "preview_failure_reason")
    end
  end

  defp maybe_put_failure_reason(server, failure_reason)
       when is_binary(failure_reason) and failure_reason != "",
       do: Map.put(server, "failure_reason", failure_reason)

  defp maybe_put_failure_reason(server, _failure_reason), do: Map.delete(server, "failure_reason")

  defp existing_command_for_port(existing, port) do
    command = usable_command(value(existing, "command"))
    existing_port = port_value(value(existing, "port"))

    if command && existing_port && existing_port != port &&
         command == default_command(existing_port) do
      default_command(port)
    else
      command
    end
  end

  defp resolve_port(attrs, existing, runtime_id, used_ports) do
    case port_value(requested_port(attrs)) || port_value(value(existing, "port")) do
      nil ->
        allocate_port(runtime_id, used_ports)

      port ->
        cond do
          port in used_ports ->
            allocate_port(runtime_id, used_ports)

          port_available?(port) ->
            {:ok, port}

          occupied_port_owned?(attrs, existing, runtime_id, port) ->
            {:ok, port}

          true ->
            allocate_port(runtime_id, [port | used_ports])
        end
    end
  end

  defp occupied_port_owned?(attrs, existing, runtime_id, port) do
    value(attrs, "_allow_occupied_preview_port") == true and
      value(existing, "runtime_id") == runtime_id and
      port_value(value(existing, "port")) == port
  end

  defp same_path?(left, right) when is_binary(left) and is_binary(right),
    do: Path.expand(left) == Path.expand(right)

  defp same_path?(_left, _right), do: false

  # PID is digits-only from a validated launcher registry; no shell is used.
  # sobelow_skip ["CI.System"]
  defp live_os_pid?(pid) when is_integer(pid), do: live_os_pid?(Integer.to_string(pid))

  defp live_os_pid?(pid) when is_binary(pid) do
    if Regex.match?(~r/\A[1-9][0-9]*\z/, pid) do
      case System.find_executable("kill") do
        nil ->
          false

        kill ->
          # kill is resolved by System.find_executable/1 and pid is digits-only.
          # sobelow_skip ["CI.System"]
          match?({_, 0}, System.cmd(kill, ["-0", pid], stderr_to_stdout: true))
      end
    else
      false
    end
  end

  defp live_os_pid?(_pid), do: false

  defp port_reachable?(port) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 250) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp allocate_port(runtime_id, used_ports) do
    {min, max} = EnvPorts.runtime_port_range()
    slots = max - min + 1
    start = :erlang.phash2(runtime_id, slots)
    used = MapSet.new(used_ports)

    0..(slots - 1)
    |> Enum.map(fn offset -> min + rem(start + offset, slots) end)
    |> Enum.find(fn port -> not MapSet.member?(used, port) and port_available?(port) end)
    |> case do
      nil -> {:error, :no_runtime_preview_port_available}
      port -> {:ok, port}
    end
  end

  defp port_available?(port) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp preview_server_from_attrs(attrs) do
    metadata = value(attrs, "metadata") || %{}
    server = value(attrs, "preview_server") || value(metadata, "preview_server")
    if is_map(server), do: server, else: %{}
  end

  defp requested_port(attrs) do
    value(attrs, "preview_port") ||
      value(attrs, "port") ||
      profile_port(value(attrs, "runtime_profile")) ||
      profile_port(value(value(attrs, "metadata") || %{}, "runtime_profile"))
  end

  defp profile_port(profile) when is_map(profile) do
    ports = value(profile, "ports") || %{}
    surfaces = value(profile, "surfaces") || []

    value(ports, @app_surface) ||
      value(ports, "http") ||
      port_from_env(value(profile, "env")) ||
      port_from_surfaces(surfaces)
  end

  defp profile_port(_), do: nil

  defp port_from_env(env) when is_map(env), do: value(env, "PORT")
  defp port_from_env(_), do: nil

  defp port_from_surfaces(surfaces) when is_list(surfaces) do
    surfaces
    |> Enum.find_value(fn
      surface when is_map(surface) -> value(surface, "port")
      _ -> nil
    end)
  end

  defp port_from_surfaces(_), do: nil

  defp command_from_attrs(attrs) do
    attrs
    |> value("runtime_profile")
    |> case do
      profile when is_map(profile) -> value(profile, "command")
      _ -> nil
    end
  end

  defp default_command(port) do
    ["bash", default_launcher_path(), "--port", Integer.to_string(port)]
  end

  defp default_launcher_path do
    configured = System.get_env("DEV_IDE_RUNTIME_PREVIEW_LAUNCHER")

    cond do
      is_binary(configured) and configured != "" ->
        configured

      Code.ensure_loaded?(Application) ->
        release_path =
          Application.app_dir(:dev_ide, Path.join(["priv", "scripts", @default_launcher]))

        source_path = Path.expand(Path.join(["priv", "scripts", @default_launcher]))

        if File.regular?(release_path), do: release_path, else: source_path

      true ->
        Path.join(["priv", "scripts", @default_launcher])
    end
  end

  defp command_list(command) when is_list(command) do
    command
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> case do
      [] -> nil
      command -> command
    end
  end

  defp command_list(command) when is_binary(command) and command != "", do: [command]
  defp command_list(_), do: nil

  defp usable_command(command) do
    command
    |> command_list()
    |> reject_legacy_command()
  end

  defp reject_legacy_command(["bash", "scripts/preview-env.sh", "dirty", "--port" | _]),
    do: nil

  defp reject_legacy_command(command), do: command

  defp runtime_socket_name(runtime_id) when is_binary(runtime_id) do
    hash =
      runtime_id
      |> :erlang.phash2(2_176_782_336)
      |> Integer.to_string(36)
      |> String.downcase()

    "rt-#{hash}.sock"
  end

  defp env_from_attrs(attrs) do
    attrs
    |> value("runtime_profile")
    |> case do
      profile when is_map(profile) -> env_map(value(profile, "env"))
      _ -> %{}
    end
  end

  defp maybe_add_profile_ports(ports, profile) when is_map(profile) do
    profile_ports =
      profile
      |> value("ports")
      |> port_map()
      |> Map.values()

    Enum.uniq(ports ++ profile_ports)
  end

  defp maybe_add_profile_ports(ports, _profile), do: ports

  defp maybe_add_port(ports, port) do
    case port_value(port) do
      port when is_integer(port) -> [port | ports]
      _ -> ports
    end
  end

  defp port_map(ports) when is_map(ports) do
    ports
    |> Enum.reduce(%{}, fn {key, port}, acc ->
      case port_value(port) do
        port when is_integer(port) -> Map.put(acc, to_string(key), port)
        _ -> acc
      end
    end)
  end

  defp port_map(_), do: %{}

  defp env_map(env) when is_map(env) do
    env
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(value) or is_integer(value) ->
        Map.put(acc, to_string(key), to_string(value))

      _entry, acc ->
        acc
    end)
  end

  defp env_map(_), do: %{}

  defp map_or_empty(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp map_or_empty(_), do: %{}

  defp port_value(port) when is_integer(port) and port > 0 and port < 65_536, do: port

  defp port_value(port) when is_binary(port) do
    case Integer.parse(port) do
      {port, ""} -> port_value(port)
      _ -> nil
    end
  end

  defp port_value(_), do: nil

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp value(_, _), do: nil

  defp atom_key("app"), do: :app
  defp atom_key("command"), do: :command
  defp atom_key("cwd"), do: :cwd
  defp atom_key("env"), do: :env
  defp atom_key("http"), do: :http
  defp atom_key("id"), do: :id
  defp atom_key("kind"), do: :kind
  defp atom_key("metadata"), do: :metadata
  defp atom_key("name"), do: :name
  defp atom_key("port"), do: :port
  defp atom_key("ports"), do: :ports
  defp atom_key("preview_port"), do: :preview_port
  defp atom_key("preview_server"), do: :preview_server
  defp atom_key("preview_status"), do: :preview_status
  defp atom_key("runtime_profile"), do: :runtime_profile
  defp atom_key("source"), do: :source
  defp atom_key("status"), do: :status
  defp atom_key("surfaces"), do: :surfaces
  defp atom_key(_), do: nil

  defp non_empty_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp non_empty_string(_), do: nil
end
