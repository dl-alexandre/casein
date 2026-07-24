defmodule CaseinWeb.WorkspaceLive.Show.Browse do
  @moduledoc false

  # Pure directory-browse helpers for the SESSIONS sidebar "Browse" tier.
  # Ported from the retired WorkspaceLive.Dashboard browse/2 so the SESSIONS
  # Browse tier shares PathSafety + forward-auth visibility rules.

  alias Casein.Files.PathSafety
  alias Casein.Workspaces.PathResolver
  alias CaseinWeb.Plugs.ForwardAuth

  import CaseinWeb.WorkspaceLive.Show.UI, only: [dom_fragment: 1]

  @type entry :: %{name: String.t(), path: String.t(), rel: String.t()}

  @type browse_node :: %{
          kind: :browse_root | :browse_dir,
          id: String.t(),
          dom_id: String.t(),
          label: String.t(),
          detail: String.t(),
          title: String.t(),
          path: String.t() | nil,
          rel: String.t(),
          expanded?: boolean(),
          children: [browse_node()] | nil,
          flat_session?: false,
          sessions: nil
        }

  @doc "Filesystem root for the Browse tier (`PathResolver.root/0`)."
  @spec root() :: String.t() | nil
  def root do
    case PathResolver.root() do
      root when is_binary(root) ->
        expanded = Path.expand(root)
        if File.dir?(expanded), do: expanded

      _ ->
        nil
    end
  end

  @doc """
  Build the Browse tier nodes for the SESSIONS tree.

  Returns `[]` when no browse root is configured. Otherwise a single
  `:browse_root` node; when expanded, children are nested `:browse_dir`
  nodes for each visible subdirectory.
  """
  @spec browse_tier(keyword()) :: [browse_node()]
  def browse_tier(opts \\ []) do
    case Keyword.get(opts, :root) || root() do
      root when is_binary(root) ->
        [browse_root_node(root, opts)]

      _ ->
        []
    end
  end

  @doc "List visible child directories under `root`/`rel`."
  @spec list_entries(String.t(), String.t() | nil, keyword()) :: [entry()]
  def list_entries(root, rel, opts \\ []) when is_binary(root) do
    case resolve_dir(root, rel, opts) do
      {:ok, dir} -> list_dir_entries(dir, rel, root, opts)
      {:error, _} -> []
    end
  end

  @doc "True when a relative dir is visible under forward-auth restrictions."
  @spec dir_rel_visible?(String.t() | nil, keyword()) :: boolean()
  def dir_rel_visible?(nil, _opts), do: true
  def dir_rel_visible?("", _opts), do: true

  def dir_rel_visible?(rel, opts) when is_binary(rel) do
    if restricted?(opts) do
      case Path.split(rel) do
        [first | _] -> String.downcase(first) in allowed_first_segments(opts)
        [] -> true
      end
    else
      true
    end
  end

  def dir_rel_visible?(_, _), do: false

  @doc "Top-level path segments a restricted viewer may see."
  @spec allowed_first_segments(keyword()) :: MapSet.t(String.t())
  def allowed_first_segments(opts) do
    identifiers = viewer_identifiers(Keyword.get(opts, :viewer))
    root = Keyword.get(opts, :root) || root()
    workspaces = Keyword.get(opts, :workspaces, [])

    workspace_segments =
      case root do
        root when is_binary(root) ->
          for ws <- workspaces,
              path = workspace_path(ws),
              is_binary(path),
              rel = relative_to_root(path, root),
              is_binary(rel),
              [first | _] <- [Path.split(rel)] do
            String.downcase(first)
          end

        _ ->
          []
      end

    MapSet.new(identifiers ++ workspace_segments)
  end

  @doc "Identity tokens used to match a viewer's own top-level directory."
  @spec viewer_identifiers(map() | nil) :: [String.t()]
  def viewer_identifiers(user) when is_map(user) do
    [:id, :username, :email]
    |> Enum.map(fn key -> Map.get(user, key) || Map.get(user, Atom.to_string(key)) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(fn value ->
      value = String.downcase(value)
      [value, value |> String.split("@") |> hd()]
    end)
    |> Enum.uniq()
  end

  def viewer_identifiers(_user), do: []

  @doc "True when forward-auth is on and the viewer is not unrestricted."
  @spec restricted?(keyword() | map()) :: boolean()
  def restricted?(opts) when is_list(opts) do
    case Keyword.fetch(opts, :restricted?) do
      {:ok, value} -> value == true
      :error -> restricted_from_viewer(Keyword.get(opts, :viewer))
    end
  end

  def restricted?(%{} = viewer), do: restricted_from_viewer(viewer)

  defp restricted_from_viewer(viewer) do
    ForwardAuth.enabled?() and not ForwardAuth.admin?(viewer)
  end

  defp browse_root_node(root, opts) do
    expanded_dirs = Keyword.get(opts, :expanded_dirs, MapSet.new())
    expanded? = MapSet.member?(expanded_dirs, "")
    opts = Keyword.put(opts, :root, root)

    children =
      if expanded? do
        dir_child_nodes(root, nil, opts)
      else
        nil
      end

    %{
      kind: :browse_root,
      id: "browse",
      dom_id: "sidebar-browse",
      label: "Browse",
      detail: Path.basename(root),
      title: "Browse directories under #{root}",
      path: root,
      rel: "",
      expanded?: expanded?,
      children: children,
      flat_session?: false,
      sessions: nil
    }
  end

  defp dir_child_nodes(root, parent_rel, opts) do
    expanded_dirs = Keyword.get(opts, :expanded_dirs, MapSet.new())

    root
    |> list_entries(parent_rel, opts)
    |> Enum.map(fn entry ->
      expanded? = MapSet.member?(expanded_dirs, entry.rel)

      children =
        if expanded? do
          dir_child_nodes(root, entry.rel, opts)
        else
          nil
        end

      %{
        kind: :browse_dir,
        id: "browse:" <> entry.rel,
        dom_id: "sidebar-browse-" <> dom_fragment(entry.rel),
        label: entry.name,
        detail: "",
        title: entry.path,
        path: entry.path,
        rel: entry.rel,
        expanded?: expanded?,
        children: children,
        flat_session?: false,
        sessions: nil
      }
    end)
  end

  defp resolve_dir(root, nil, _opts), do: {:ok, root}
  defp resolve_dir(root, "", _opts), do: {:ok, root}

  defp resolve_dir(root, rel, opts) when is_binary(rel) do
    with {:ok, dir} <- PathSafety.resolve(root, rel),
         true <- File.dir?(dir) || {:error, :not_a_directory},
         true <- dir_rel_visible?(rel, opts) || {:error, :forbidden} do
      {:ok, dir}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_dir_entries(dir, rel, root, opts) do
    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.filter(fn name ->
          not String.starts_with?(name, ".") and not PathSafety.ignored_dir?(name) and
            File.dir?(Path.join(dir, name))
        end)
        |> Enum.map(fn name ->
          entry_rel =
            cond do
              is_binary(rel) and rel != "" -> Path.join(rel, name)
              true -> name
            end

          %{name: name, path: Path.join(dir, name), rel: entry_rel}
        end)
        |> Enum.filter(&dir_rel_visible?(&1.rel, Keyword.put(opts, :root, root)))

      {:error, _} ->
        []
    end
  end

  defp workspace_path(ws) when is_map(ws) do
    Map.get(ws, :path) || Map.get(ws, "path") || Map.get(ws, :host_path) ||
      Map.get(ws, "host_path")
  end

  defp workspace_path(_), do: nil

  defp relative_to_root(path, root) do
    expanded = Path.expand(path)

    cond do
      expanded == root ->
        nil

      String.starts_with?(expanded, root <> "/") ->
        String.replace_prefix(expanded, root <> "/", "")

      true ->
        nil
    end
  end
end
