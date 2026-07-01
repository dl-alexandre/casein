defmodule DevIDE.LanPathResolver do
  @moduledoc """
  Resolves LAN-friendly URL paths to local filesystem workspace roots.

  In LAN mode this lets a URL like `/aws` mean `$DEV_IDE_LAN_PATH_ROOT/aws`
  while keeping reserved application prefixes (`/api`, `/assets`, `/live`, ...)
  under normal Phoenix routing.
  """

  alias DevIDE.Files.PathSafety

  @reserved_prefixes ~w(
    api
    assets
    dev
    live
    pair
    preview-artifacts
    preview-proxy
    workspaces
  )

  @type resolution :: %{
          path: String.t(),
          relative_path: String.t(),
          route_path: String.t()
        }

  @spec resolve([String.t()] | nil) ::
          {:ok, resolution()}
          | {:error,
             :disabled
             | :invalid_root
             | :missing_root
             | :reserved_prefix
             | :invalid_path
             | :outside_root
             | :symlink_escape
             | :too_deep
             | :not_found}
  def resolve(segments) do
    segments = normalize_segments(segments)

    cond do
      not enabled?() ->
        {:error, :disabled}

      reserved?(segments) ->
        {:error, :reserved_prefix}

      not valid_segments?(segments) ->
        {:error, :invalid_path}

      true ->
        resolve_segments(segments)
    end
  end

  @spec enabled?() :: boolean()
  def enabled? do
    truthy?(Application.get_env(:dev_ide, :lan_mode)) and
      truthy?(Application.get_env(:dev_ide, :lan_friendly_paths))
  end

  @spec root() :: String.t() | nil
  def root do
    Application.get_env(:dev_ide, :lan_path_root) ||
      Application.get_env(:dev_ide, :home_workspace_path)
  end

  @spec reserved_prefix?(String.t()) :: boolean()
  def reserved_prefix?(segment) when is_binary(segment) do
    String.downcase(segment) in @reserved_prefixes
  end

  def reserved_prefix?(_segment), do: false

  defp resolve_segments(segments) do
    case root_path() do
      {:ok, root} ->
        relative = relative_path(segments)

        with {:ok, path} <- PathSafety.resolve(root, relative),
             true <- File.dir?(path) do
          {:ok,
           %{
             path: path,
             relative_path: relative,
             route_path: route_path(segments)
           }}
        else
          false -> {:error, :not_found}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp root_path do
    case root() do
      path when is_binary(path) and path != "" ->
        expanded = Path.expand(path)

        if Path.type(expanded) == :absolute and File.dir?(expanded) do
          {:ok, expanded}
        else
          {:error, :invalid_root}
        end

      _ ->
        {:error, :missing_root}
    end
  end

  defp normalize_segments(nil), do: []

  defp normalize_segments(segments) when is_list(segments) do
    Enum.reject(segments, &(&1 in [nil, ""]))
  end

  defp normalize_segments(_segments), do: []

  defp reserved?([first | _]), do: reserved_prefix?(first)
  defp reserved?([]), do: false

  defp valid_segments?(segments) do
    Enum.all?(segments, fn
      segment when is_binary(segment) ->
        segment not in [".", ".."] and not String.contains?(segment, "/") and
          String.valid?(segment)

      _ ->
        false
    end)
  end

  defp route_path(segments) do
    case segments do
      [] -> "/"
      segments -> "/" <> Enum.map_join(segments, "/", &URI.encode/1)
    end
  end

  defp relative_path([]), do: ""
  defp relative_path(segments), do: Path.join(segments)

  defp truthy?(true), do: true
  defp truthy?(value) when is_binary(value), do: value in ~w(1 true TRUE yes YES on ON)
  defp truthy?(_value), do: false
end
