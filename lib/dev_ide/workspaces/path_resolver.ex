defmodule Casein.Workspaces.PathResolver do
  @moduledoc """
  Resolves URL path segments to workspace roots, and workspaces back to
  canonical path routes.

  A URL like `/aws/myproject/lib`
  resolves under `root/0` and then **walks up** to the nearest ancestor that
  is a workspace root — a directory containing `.git`, one matching a
  persisted `workspace_records.host_path`, or the configured
  `:home_workspace_path`. Segments below the workspace root are returned as
  `inner_segments`: they stay in the requested route but never change which
  workspace mounts, so deep links cannot mint per-directory workspaces.

  When no ancestor matches, the requested directory itself is the workspace
  root (`inner_segments: []`), preserving plain folder-attach behavior.

  Root precedence: `:lan_path_root || :workspaces_root || :home_workspace_path`.

  Incoming segments are expected already percent-decoded (Phoenix decodes
  path params); generated routes percent-encode each segment.
  """

  alias Casein.Files.PathSafety
  alias Casein.Workspaces.State

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
          workspace_path: String.t(),
          workspace_route: String.t(),
          route_path: String.t(),
          inner_segments: [String.t()],
          requested_path: String.t()
        }

  @type error ::
          :invalid_root
          | :missing_root
          | :reserved_prefix
          | :invalid_path
          | :outside_root
          | :symlink_escape
          | :too_deep
          | :not_found

  @spec resolve([String.t()] | nil) :: {:ok, resolution()} | {:error, error()}
  def resolve(segments) do
    segments = normalize_segments(segments)

    cond do
      reserved?(segments) -> {:error, :reserved_prefix}
      not valid_segments?(segments) -> {:error, :invalid_path}
      true -> resolve_segments(segments)
    end
  end

  @doc """
  The canonical path route for a workspace (or any absolute path), the
  inverse of `resolve/1`. Returns `:error` when the path lies outside
  `root/0` or its route would be rejected by `resolve/1` (reserved prefix,
  invalid segment, too deep, symlink escape) — callers fall back to the
  `/workspaces/:id` form.
  """
  @spec route_for(%{path: String.t() | nil} | String.t() | nil) ::
          {:ok, String.t()} | :error
  def route_for(%{path: path}), do: route_for(path)

  def route_for(path) when is_binary(path) and path != "" do
    case root_path() do
      {:ok, root} ->
        expanded = Path.expand(path)

        cond do
          expanded == root ->
            {:ok, "/"}

          String.starts_with?(expanded, root <> "/") ->
            segments = expanded |> Path.relative_to(root) |> Path.split()
            route_for_segments(root, segments)

          true ->
            :error
        end

      {:error, _reason} ->
        :error
    end
  end

  def route_for(_other), do: :error

  @spec root() :: String.t() | nil
  def root do
    Application.get_env(:dev_ide, :lan_path_root) ||
      Application.get_env(:dev_ide, :workspaces_root) ||
      Application.get_env(:dev_ide, :home_workspace_path)
  end

  @spec reserved_prefix?(String.t()) :: boolean()
  def reserved_prefix?(segment) when is_binary(segment) do
    String.downcase(segment) in @reserved_prefixes
  end

  def reserved_prefix?(_segment), do: false

  defp route_for_segments(root, segments) do
    with false <- reserved?(segments),
         true <- valid_segments?(segments),
         {:ok, _path} <- PathSafety.resolve(root, Path.join(segments)) do
      {:ok, route_path(segments)}
    else
      _ -> :error
    end
  end

  defp resolve_segments(segments) do
    with {:ok, root} <- root_path(),
         {:ok, path} <- PathSafety.resolve(root, relative_path(segments)),
         true <- File.dir?(path) do
      workspace_path = nearest_workspace_root(path, root) || path
      inner_count = length(Path.split(path)) - length(Path.split(workspace_path))

      {workspace_segments, inner_segments} =
        Enum.split(segments, length(segments) - inner_count)

      {:ok,
       %{
         workspace_path: workspace_path,
         workspace_route: route_path(workspace_segments),
         route_path: route_path(segments),
         inner_segments: inner_segments,
         requested_path: path
       }}
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # Nearest (deepest) ancestor of `path` — strictly below `root` — that is a
  # workspace root: has `.git` (File.exists?/1, so worktree `.git` files
  # count), matches a persisted record's host_path, or is the configured
  # home workspace path. The root itself is excluded: even when it is a
  # marker (home == root, or a repo at the root) it must not swallow its
  # children, which are independent workspaces. Record matches are fetched
  # in one batch query for the whole ancestor chain.
  defp nearest_workspace_root(path, root) do
    chain = ancestor_chain(path, root)
    records = State.records_for_host_paths(chain)
    home = expanded_home()

    Enum.find(chain, fn dir ->
      File.exists?(Path.join(dir, ".git")) or Map.has_key?(records, dir) or dir == home
    end)
  end

  defp ancestor_chain(path, root) do
    Stream.unfold(path, fn
      nil -> nil
      ^root -> nil
      p -> {p, Path.dirname(p)}
    end)
    |> Enum.to_list()
  end

  defp expanded_home do
    case Application.get_env(:dev_ide, :home_workspace_path) do
      home when is_binary(home) and home != "" -> Path.expand(home)
      _ -> nil
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

  defp route_path([]), do: "/"

  defp route_path(segments) do
    "/" <> Enum.map_join(segments, "/", &encode_segment/1)
  end

  # Path-segment encoding: everything but RFC 3986 unreserved characters is
  # escaped, so `?`, `#`, `%`, and spaces in directory names round-trip.
  defp encode_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp relative_path([]), do: ""
  defp relative_path(segments), do: Path.join(segments)
end
