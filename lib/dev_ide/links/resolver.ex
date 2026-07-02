defmodule DevIDE.Links.Resolver do
  @moduledoc """
  Resolves candidate links into verified, typed targets.

  Scanners and explicit API callers both enter here. Missing files and
  undetected localhost ports return `:skip` so terminal linkification can stay
  quiet, while forbidden or malformed inputs return `{:error, reason}`.
  """

  alias DevIDE.Links.Resolver.Ctx
  alias DevIDE.Previews.Url
  alias DevIDE.Workspaces
  alias DevIDE.Workspaces.FileAccess

  @type target ::
          {:file, %{path: String.t(), line: pos_integer() | nil, col: pos_integer() | nil}}
          | {:markdown, %{path: String.t(), anchor: String.t() | nil}}
          | {:dir, String.t()}
          | {:localhost, %{url: String.t(), port: :inet.port_number()}}
          | {:external, %{url: String.t()}}

  @spec resolve(String.t(), Ctx.t()) :: {:ok, target()} | :skip | {:error, term()}
  def resolve(raw, %Ctx{} = ctx) when is_binary(raw) do
    target = String.trim(raw)

    cond do
      target == "" ->
        :skip

      explicit_uri?(target) ->
        resolve_uri(target, ctx)

      true ->
        {path, fragment} = split_fragment(target)
        {path, line, col} = split_position(path)
        resolve_path(path, ctx, line, col, fragment)
    end
  end

  def resolve(_, %Ctx{}), do: {:error, :invalid_target}

  defp resolve_uri(target, ctx) do
    case URI.parse(target) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        resolve_http_uri(target, ctx)

      %URI{scheme: "file", path: path, fragment: fragment} when is_binary(path) ->
        path = URI.decode(path)
        {path, line, col} = split_position(path)
        resolve_path(path, ctx, line, col, fragment)

      %URI{scheme: scheme} when is_binary(scheme) ->
        {:error, :scheme_not_allowed}

      _ ->
        {:error, :malformed_uri}
    end
  end

  defp resolve_http_uri(target, ctx) do
    normalized = Url.normalize_localhost(target)

    case URI.parse(normalized) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        port = uri.port || default_port(scheme)

        cond do
          loopback_host?(host) and detected_port?(ctx.workspace, port) ->
            {:ok, {:localhost, %{url: normalized, port: port}}}

          loopback_host?(host) ->
            :skip

          true ->
            {:ok, {:external, %{url: normalized}}}
        end

      _ ->
        {:error, :malformed_uri}
    end
  end

  defp resolve_path(path, ctx, line, col, fragment) when is_binary(path) do
    with {:ok, loc} <- Workspaces.safe_host_loc(ctx.workspace) do
      root = root_from_loc(loc)

      path
      |> path_candidates(ctx.base_dir, root)
      |> classify_first_existing(loc, root, line, col, fragment)
    end
  end

  defp resolve_path(_, _ctx, _line, _col, _fragment), do: {:error, :invalid_path}

  defp classify_first_existing(candidates, loc, root, line, col, fragment) do
    result =
      candidates
      |> Enum.uniq()
      |> Enum.reduce_while({:pending, :skip, false, false}, fn abs_path,
                                                               {:pending, acc, seen_inside?,
                                                                seen_outside?} ->
        case relative_to_root(abs_path, root) do
          {:ok, rel} ->
            case FileAccess.stat(loc, rel) do
              {:ok, %{type: :directory}} ->
                {:halt, {:done, {:ok, {:dir, rel}}}}

              {:ok, %{type: :regular}} ->
                {:halt, {:done, {:ok, classify_file(rel, line, col, fragment)}}}

              {:ok, _} ->
                {:halt, {:done, {:error, :unsupported_file_type}}}

              {:error, reason} when reason in [:enoent, :enotdir, :missing_path] ->
                {:cont, {:pending, acc, true, seen_outside?}}

              {:error, reason} when reason in [:outside_root, :symlink_escape, :too_deep] ->
                {:halt, {:done, {:error, reason}}}

              {:error, _reason} ->
                {:cont, {:pending, acc, true, seen_outside?}}
            end

          {:error, :outside_root} ->
            {:cont, {:pending, acc, seen_inside?, true}}
        end
      end)

    case result do
      {:done, result} -> result
      {:pending, _result, false, true} -> {:error, :outside_root}
      {:pending, result, _seen_inside?, _seen_outside?} -> result
    end
  end

  defp classify_file(rel, line, col, fragment) do
    case rel |> Path.extname() |> String.downcase() do
      ext when ext in [".md", ".markdown"] ->
        {:markdown, %{path: rel, anchor: fragment}}

      _ ->
        {:file, %{path: rel, line: line, col: col}}
    end
  end

  defp path_candidates(path, base_dir, root) do
    expanded = expand_tilde(path)

    cond do
      Path.type(expanded) == :absolute ->
        [Path.expand(expanded)]

      is_binary(base_dir) and base_dir != "" ->
        [Path.expand(expanded, base_dir), Path.expand(expanded, root)]

      true ->
        [Path.expand(expanded, root)]
    end
  end

  defp expand_tilde("~") do
    System.user_home!()
  rescue
    _ -> "~"
  end

  defp expand_tilde("~/" <> rest) do
    Path.join(expand_tilde("~"), rest)
  end

  defp expand_tilde(path), do: path

  defp relative_to_root(abs_path, root) do
    root = Path.expand(root)
    abs_path = Path.expand(abs_path)
    rel = Path.relative_to(abs_path, root)

    cond do
      abs_path == root -> {:ok, ""}
      rel == abs_path or String.starts_with?(rel, "..") -> {:error, :outside_root}
      true -> {:ok, rel}
    end
  end

  defp split_fragment(path) do
    case String.split(path, "#", parts: 2) do
      [path, fragment] -> {path, URI.decode(fragment)}
      [path] -> {path, nil}
    end
  end

  defp split_position(path) do
    case Regex.run(~r/^(.+?):(\d+)(?::(\d+))?$/, path) do
      [_, body, line] ->
        {body, positive_int(line), nil}

      [_, body, line, col] ->
        {body, positive_int(line), positive_int(col)}

      _ ->
        {path, nil, nil}
    end
  end

  defp positive_int(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      _ -> nil
    end
  end

  defp explicit_uri?(target) do
    case URI.parse(target) do
      %URI{scheme: scheme} when scheme in ["http", "https", "file"] ->
        true

      %URI{scheme: scheme} when is_binary(scheme) ->
        not path_position_target?(target)

      _ ->
        false
    end
  end

  defp path_position_target?(target) do
    case Regex.run(~r/^(.+?):\d+(?::\d+)?(?:#.*)?$/, target) do
      [_, body] ->
        String.contains?(body, "/") or String.starts_with?(body, [".", "~"]) or
          Path.extname(body) != ""

      _ ->
        false
    end
  end

  defp loopback_host?(host), do: host in ["localhost", "127.0.0.1", "0.0.0.0", "::1"]

  defp detected_port?(workspace, port) when is_integer(port) do
    workspace
    |> metadata_map()
    |> metadata_value(:detected_ports)
    |> List.wrap()
    |> Enum.any?(&(&1 == port))
  end

  defp detected_port?(_, _), do: false

  defp metadata_map(workspace) when is_map(workspace) do
    case Map.get(workspace, :metadata) || Map.get(workspace, "metadata") do
      metadata when is_map(metadata) -> metadata
      _ -> %{}
    end
  end

  defp metadata_map(_), do: %{}

  defp metadata_value(metadata, key) when is_map(metadata) and is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp root_from_loc({:local, root}), do: root
  defp root_from_loc({:remote, _host, root}), do: root

  defp default_port("https"), do: 443
  defp default_port(_), do: 80
end
