defmodule Casein.Workspaces.PathResolverTest do
  use Casein.TestCase, async: false

  alias Casein.Workspace
  alias Casein.Workspaces.PathResolver
  alias Casein.Workspaces.State
  alias Casein.Workspaces.State.MemoryAdapter

  @config_keys [:lan_path_root, :workspaces_root, :home_workspace_path]

  setup do
    MemoryAdapter.clear()
    previous = Map.new(@config_keys, &{&1, Application.get_env(:casein, &1)})

    root =
      Path.join(System.tmp_dir!(), "casein-path-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    Application.put_env(:casein, :lan_path_root, root)
    Application.delete_env(:casein, :workspaces_root)
    Application.delete_env(:casein, :home_workspace_path)

    on_exit(fn ->
      MemoryAdapter.clear()

      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:casein, key)
        {key, value} -> Application.put_env(:casein, key, value)
      end)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp mkdirs!(root, relative) do
    path = Path.join([root | relative])
    File.mkdir_p!(path)
    path
  end

  defp mark_git_dir!(path), do: File.mkdir_p!(Path.join(path, ".git"))
  defp mark_git_file!(path), do: File.write!(Path.join(path, ".git"), "gitdir: elsewhere\n")

  defp sync_record!(id, path) do
    {:ok, _} =
      State.sync(%Workspace{
        id: id,
        name: Path.basename(path),
        status: :running,
        path: path,
        metadata: %{}
      })
  end

  describe "resolve/1 basics" do
    test "resolves the empty route to the root itself", %{root: root} do
      assert {:ok,
              %{
                workspace_path: ^root,
                workspace_route: "/",
                route_path: "/",
                inner_segments: [],
                requested_path: ^root
              }} = PathResolver.resolve([])
    end

    test "a plain directory with no markers is its own workspace root", %{root: root} do
      plain = mkdirs!(root, ["plain"])

      assert {:ok, %{workspace_path: ^plain, workspace_route: "/plain", inner_segments: []}} =
               PathResolver.resolve(["plain"])
    end

    test "rejects reserved application prefixes" do
      assert {:error, :reserved_prefix} = PathResolver.resolve(["api"])
      assert {:error, :reserved_prefix} = PathResolver.resolve(["workspaces", "alpha"])
    end

    test "rejects invalid path segments" do
      assert {:error, :invalid_path} = PathResolver.resolve([".."])
      assert {:error, :invalid_path} = PathResolver.resolve(["nested/path"])
    end

    test "rejects routes deeper than the path-safety segment cap" do
      assert {:error, :too_deep} = PathResolver.resolve(List.duplicate("d", 33))
    end

    test "missing directories are not found", %{root: _root} do
      assert {:error, :not_found} = PathResolver.resolve(["nope"])
    end

    test "errors when no root is configured" do
      Application.delete_env(:casein, :lan_path_root)
      assert {:error, :missing_root} = PathResolver.resolve(["anything"])
    end

    test "rejects symlinks that escape the root", %{root: root} do
      outside =
        Path.join(System.tmp_dir!(), "casein-path-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)

      case File.ln_s(outside, Path.join(root, "outside")) do
        :ok -> assert {:error, :symlink_escape} = PathResolver.resolve(["outside"])
        {:error, :eexist} -> flunk("test symlink already exists")
        {:error, :eperm} -> :ok
      end
    end
  end

  describe "walk-up" do
    test "walks up to the nearest .git-directory ancestor", %{root: root} do
      repo = mkdirs!(root, ["repo"])
      mark_git_dir!(repo)
      mkdirs!(root, ["repo", "lib", "foo"])

      assert {:ok,
              %{
                workspace_path: ^repo,
                workspace_route: "/repo",
                route_path: "/repo/lib/foo",
                inner_segments: ["lib", "foo"]
              }} = PathResolver.resolve(["repo", "lib", "foo"])
    end

    test "a git-worktree .git file also marks a workspace root", %{root: root} do
      wt = mkdirs!(root, ["wt"])
      mark_git_file!(wt)
      mkdirs!(root, ["wt", "sub"])

      assert {:ok, %{workspace_path: ^wt, inner_segments: ["sub"]}} =
               PathResolver.resolve(["wt", "sub"])
    end

    test "walks up to a persisted workspace record's host_path", %{root: root} do
      proj = mkdirs!(root, ["proj"])
      mkdirs!(root, ["proj", "docs"])
      sync_record!("manager-uuid", proj)

      assert {:ok, %{workspace_path: ^proj, workspace_route: "/proj", inner_segments: ["docs"]}} =
               PathResolver.resolve(["proj", "docs"])
    end

    test "the deepest matching ancestor wins", %{root: root} do
      outer = mkdirs!(root, ["outer"])
      inner = mkdirs!(root, ["outer", "inner"])
      mark_git_dir!(outer)
      mark_git_dir!(inner)
      mkdirs!(root, ["outer", "inner", "x"])

      assert {:ok, %{workspace_path: ^inner, workspace_route: "/outer/inner"}} =
               PathResolver.resolve(["outer", "inner", "x"])
    end

    test "never walks above the configured root", %{root: root} do
      # The root's parent is a repo; a plain dir under the root must still
      # fall back to itself, not to the out-of-root ancestor.
      nested_root = mkdirs!(root, ["nested"])
      mark_git_dir!(root)
      Application.put_env(:casein, :lan_path_root, nested_root)
      plain = mkdirs!(root, ["nested", "plain"])

      assert {:ok, %{workspace_path: ^plain}} = PathResolver.resolve(["plain"])
    end

    test "the root itself never swallows its children", %{root: root} do
      # Even when the root is a marker (a repo, or home == root), top-level
      # directories under it are independent workspaces, not inner segments.
      mark_git_dir!(root)
      Application.put_env(:casein, :home_workspace_path, root)
      plain = mkdirs!(root, ["plain"])

      assert {:ok, %{workspace_path: ^plain, inner_segments: []}} =
               PathResolver.resolve(["plain"])
    end

    test "the home workspace path is a workspace root marker", %{root: root} do
      homews = mkdirs!(root, ["homews"])
      mkdirs!(root, ["homews", "deep"])
      Application.put_env(:casein, :home_workspace_path, homews)

      assert {:ok, %{workspace_path: ^homews, inner_segments: ["deep"]}} =
               PathResolver.resolve(["homews", "deep"])
    end
  end

  describe "route_for/1 and encoding" do
    test "is the inverse of resolve for in-root paths", %{root: root} do
      repo = mkdirs!(root, ["repo"])
      mark_git_dir!(repo)

      assert {:ok, "/repo"} = PathResolver.route_for(repo)
      assert {:ok, "/repo"} = PathResolver.route_for(%{path: repo})
      assert {:ok, "/"} = PathResolver.route_for(root)
    end

    test "returns :error outside the root and for blank input", %{root: _root} do
      assert :error = PathResolver.route_for("/definitely/elsewhere")
      assert :error = PathResolver.route_for(%{path: nil})
      assert :error = PathResolver.route_for(nil)
    end

    test "returns :error for a directory whose route would be reserved", %{root: root} do
      api = mkdirs!(root, ["api"])
      assert :error = PathResolver.route_for(api)
    end

    test "percent-encodes awkward directory names and round-trips them", %{root: root} do
      name = "sp ace%#?ü"
      dir = mkdirs!(root, [name])
      mark_git_dir!(dir)

      assert {:ok, route} = PathResolver.route_for(dir)
      refute String.contains?(route, [" ", "#", "?"])

      # Simulate the browser hop: Phoenix hands the LiveView decoded segments.
      segments =
        route
        |> String.trim_leading("/")
        |> String.split("/")
        |> Enum.map(&URI.decode/1)

      assert {:ok, %{workspace_path: ^dir, workspace_route: ^route}} =
               PathResolver.resolve(segments)
    end

    test "resolve |> route_for round-trips to the workspace route", %{root: root} do
      repo = mkdirs!(root, ["team", "repo"])
      mark_git_dir!(repo)
      mkdirs!(root, ["team", "repo", "lib"])

      assert {:ok, resolution} = PathResolver.resolve(["team", "repo", "lib"])
      assert {:ok, route} = PathResolver.route_for(resolution.workspace_path)
      assert route == resolution.workspace_route
    end
  end

  describe "root/0 precedence" do
    test "prefers :lan_path_root, then :workspaces_root, then :home_workspace_path",
         %{root: root} do
      assert PathResolver.root() == root

      Application.delete_env(:casein, :lan_path_root)
      Application.put_env(:casein, :workspaces_root, "/tmp/wsroot")
      Application.put_env(:casein, :home_workspace_path, "/tmp/home")
      assert PathResolver.root() == "/tmp/wsroot"

      Application.delete_env(:casein, :workspaces_root)
      assert PathResolver.root() == "/tmp/home"
    end
  end
end
