defmodule Casein.Runtimes.Profile do
  @moduledoc """
  Normalized dev-server intent for a runtime.

  Runtime profiles are metadata only. They describe how a future provisioner
  should start and expose a previewable server for a runtime, without adding
  command execution authority to the runtime registry.
  """

  alias Casein.Runtimes.Runtime

  @type t :: map()

  @builtins %{
    "phoenix" => %{
      "kind" => "phoenix",
      "command" => ["mise", "exec", "--", "mix", "phx.server"],
      "ports" => %{"app" => 4000},
      "surfaces" => [%{"name" => "app", "port" => 4000}]
    },
    "vite" => %{
      "kind" => "vite",
      "command" => ["npm", "run", "dev", "--", "--host", "0.0.0.0"],
      "ports" => %{"app" => 5173},
      "surfaces" => [%{"name" => "app", "port" => 5173}]
    },
    "static" => %{
      "kind" => "static",
      "command" => ["python3", "-m", "http.server", "8000"],
      "ports" => %{"app" => 8000},
      "surfaces" => [%{"name" => "app", "port" => 8000}]
    },
    "custom" => %{
      "kind" => "custom",
      "command" => nil,
      "ports" => %{},
      "surfaces" => []
    }
  }

  @doc "Extract and normalize a runtime profile from request attrs or metadata."
  @spec from_attrs(map()) :: {:ok, t() | nil} | {:error, term()}
  def from_attrs(attrs) when is_map(attrs) do
    profile =
      value(attrs, "runtime_profile") ||
        value(attrs, "profile") ||
        value(value(attrs, "runtime") || %{}, "profile") ||
        value(value(attrs, "metadata") || %{}, "runtime_profile")

    normalize(profile)
  end

  def from_attrs(_attrs), do: {:ok, nil}

  @doc "Normalize a runtime profile map, name, or nil."
  @spec normalize(term()) :: {:ok, t() | nil} | {:error, term()}
  def normalize(nil), do: {:ok, nil}
  def normalize(""), do: {:ok, nil}

  def normalize(name) when is_atom(name), do: normalize(Atom.to_string(name))

  def normalize(name) when is_binary(name) do
    name = normalize_name(name)

    case Map.fetch(@builtins, name) do
      {:ok, profile} -> {:ok, Map.put(profile, "name", name)}
      :error -> {:error, {:unknown_runtime_profile, name}}
    end
  end

  def normalize(profile) when is_map(profile) do
    name = profile |> value("name") |> name_or_custom()
    builtin = Map.get(@builtins, name, @builtins["custom"])
    merged = Map.merge(builtin, stringify_keys(profile))

    with {:ok, command} <- command(value(merged, "command")),
         {:ok, ports} <- ports(value(merged, "ports") || %{}),
         {:ok, surfaces} <- surfaces(value(merged, "surfaces") || [], ports),
         {:ok, env} <- env(value(merged, "env") || %{}),
         {:ok, health_check} <- health_check(value(merged, "health_check")) do
      {:ok,
       %{
         "name" => name,
         "kind" => value(merged, "kind") || name,
         "command" => command,
         "cwd" => non_empty_string(value(merged, "cwd")),
         "env" => env,
         "ports" => ports,
         "surfaces" => surfaces,
         "health_check" => health_check
       }
       |> put_optional("metadata", map_or_empty(value(merged, "metadata")))}
    end
  end

  def normalize(_profile), do: {:error, :invalid_runtime_profile}

  @doc "Return the normalized profile stored on a runtime."
  @spec for_runtime(Runtime.t()) :: t() | nil
  def for_runtime(%Runtime{metadata: metadata}) when is_map(metadata) do
    case value(metadata, "runtime_profile") do
      profile when is_map(profile) -> profile
      _ -> nil
    end
  end

  def for_runtime(_runtime), do: nil

  @doc """
  Build preview surface payloads for a runtime profile.

  These payloads are intentionally plain maps so callers can turn them into
  `Casein.Previews.Surface` structs or API JSON without coupling this module to
  the preview context.
  """
  @spec preview_surfaces(Runtime.t(), keyword()) :: [map()]
  def preview_surfaces(%Runtime{} = runtime, opts \\ []) do
    profile = for_runtime(runtime)
    base_url = Keyword.get(opts, :base_url)

    case profile do
      %{"surfaces" => surfaces, "ports" => ports} ->
        Enum.flat_map(surfaces, &surface_payload(&1, ports, runtime, base_url))

      _ ->
        []
    end
  end

  defp surface_payload(surface, ports, runtime, base_url) do
    name = value(surface, "name") || "app"
    port = port_value(value(surface, "port") || Map.get(ports, name))

    cond do
      is_binary(value(surface, "url")) ->
        [payload(runtime, name, value(surface, "url"), port)]

      is_integer(port) and is_binary(base_url) ->
        [payload(runtime, name, join_base_url(base_url, port), port)]

      is_integer(port) ->
        [payload(runtime, name, "http://localhost:#{port}", port)]

      true ->
        []
    end
  end

  defp payload(%Runtime{} = runtime, name, url, port) do
    %{
      "name" => name,
      "title" => title(name),
      "url" => url,
      "port" => port,
      "source" => "runtime",
      "runtime_id" => runtime.id,
      "runtime_status" => runtime.status,
      "surface_key" => "runtime:#{runtime.id}:#{name}"
    }
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new()
  end

  defp command(nil), do: {:ok, nil}
  defp command(command) when is_list(command), do: string_list(command)
  defp command(command) when is_binary(command), do: {:ok, [command]}
  defp command(_), do: {:error, :invalid_runtime_profile_command}

  defp ports(ports) when is_map(ports) do
    ports
    |> Enum.reduce_while({:ok, %{}}, fn {name, port}, {:ok, acc} ->
      case port_value(port) do
        port when is_integer(port) ->
          {:cont, {:ok, Map.put(acc, to_string(name), port)}}

        _ ->
          {:halt, {:error, {:invalid_runtime_profile_port, to_string(name)}}}
      end
    end)
  end

  defp ports(_), do: {:error, :invalid_runtime_profile_ports}

  defp surfaces(surfaces, ports) when is_list(surfaces) do
    surfaces
    |> Enum.reduce_while({:ok, []}, fn surface, {:ok, acc} ->
      case surface(surface, ports) do
        {:ok, normalized} -> {:cont, {:ok, acc ++ [normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp surfaces(_surfaces, _ports), do: {:error, :invalid_runtime_profile_surfaces}

  defp surface(surface, ports) when is_binary(surface) do
    surface(%{"name" => surface}, ports)
  end

  defp surface(surface, ports) when is_map(surface) do
    name = value(surface, "name") || "app"
    port = value(surface, "port") || Map.get(ports, name)
    url = non_empty_string(value(surface, "url"))

    with {:ok, port} <- optional_port(port) do
      {:ok,
       %{
         "name" => to_string(name),
         "port" => port,
         "url" => url
       }
       |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
       |> Map.new()}
    end
  end

  defp surface(_surface, _ports), do: {:error, :invalid_runtime_profile_surface}

  defp env(env) when is_map(env) do
    env
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      cond do
        is_binary(value) or is_integer(value) ->
          {:cont, {:ok, Map.put(acc, to_string(key), to_string(value))}}

        true ->
          {:halt, {:error, {:invalid_runtime_profile_env, key}}}
      end
    end)
  end

  defp env(_env), do: {:error, :invalid_runtime_profile_env}

  defp health_check(nil), do: {:ok, nil}
  defp health_check(check) when is_map(check), do: {:ok, stringify_keys(check)}
  defp health_check(_check), do: {:error, :invalid_runtime_profile_health_check}

  defp optional_port(nil), do: {:ok, nil}

  defp optional_port(port) do
    case port_value(port) do
      value when is_integer(value) -> {:ok, value}
      _ -> {:error, {:invalid_runtime_profile_port, port}}
    end
  end

  defp port_value(port) when is_integer(port) and port > 0 and port < 65_536, do: port

  defp port_value(port) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} -> port_value(parsed)
      _ -> nil
    end
  end

  defp port_value(_), do: nil

  defp string_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn
      value, {:ok, acc} when is_binary(value) and value != "" -> {:cont, {:ok, acc ++ [value]}}
      _value, _acc -> {:halt, {:error, :invalid_runtime_profile_command}}
    end)
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp value(_, _), do: nil

  defp atom_key("command"), do: :command
  defp atom_key("cwd"), do: :cwd
  defp atom_key("env"), do: :env
  defp atom_key("health_check"), do: :health_check
  defp atom_key("kind"), do: :kind
  defp atom_key("metadata"), do: :metadata
  defp atom_key("name"), do: :name
  defp atom_key("port"), do: :port
  defp atom_key("ports"), do: :ports
  defp atom_key("profile"), do: :profile
  defp atom_key("runtime"), do: :runtime
  defp atom_key("runtime_profile"), do: :runtime_profile
  defp atom_key("surfaces"), do: :surfaces
  defp atom_key("url"), do: :url
  defp atom_key(_), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp map_or_empty(map) when is_map(map), do: stringify_keys(map)
  defp map_or_empty(_), do: %{}

  defp name_or_custom(nil), do: "custom"
  defp name_or_custom(name), do: normalize_name(to_string(name))

  defp normalize_name(name), do: name |> String.trim() |> String.downcase()

  defp non_empty_string(value) when is_binary(value) and value != "", do: value
  defp non_empty_string(_value), do: nil

  defp put_optional(map, _key, empty) when empty in [%{}, nil], do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)

  defp title("app"), do: "App"
  defp title(name), do: String.capitalize(name)

  defp join_base_url(base_url, port) do
    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>(":#{port}")
  end
end
