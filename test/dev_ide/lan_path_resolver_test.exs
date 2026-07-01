defmodule DevIDE.LanPathResolverTest do
  use ExUnit.Case, async: false

  alias DevIDE.LanPathResolver

  setup do
    prev_lan_mode = Application.get_env(:dev_ide, :lan_mode)
    prev_friendly = Application.get_env(:dev_ide, :lan_friendly_paths)
    prev_root = Application.get_env(:dev_ide, :lan_path_root)
    prev_home = Application.get_env(:dev_ide, :home_workspace_path)

    root =
      Path.join(System.tmp_dir!(), "devide-lan-path-root-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    Application.put_env(:dev_ide, :lan_mode, true)
    Application.put_env(:dev_ide, :lan_friendly_paths, true)
    Application.put_env(:dev_ide, :lan_path_root, root)
    Application.delete_env(:dev_ide, :home_workspace_path)

    on_exit(fn ->
      restore(:lan_mode, prev_lan_mode)
      restore(:lan_friendly_paths, prev_friendly)
      restore(:lan_path_root, prev_root)
      restore(:home_workspace_path, prev_home)
      File.rm_rf(root)
    end)

    %{root: root}
  end

  test "resolves root to the configured LAN path root", %{root: root} do
    assert {:ok, %{path: ^root, relative_path: "", route_path: "/"}} =
             LanPathResolver.resolve([])
  end

  test "resolves URL path segments under the configured root", %{root: root} do
    aws = Path.join(root, "aws")
    File.mkdir_p!(aws)

    assert {:ok, %{path: ^aws, relative_path: "aws", route_path: "/aws"}} =
             LanPathResolver.resolve(["aws"])
  end

  test "rejects reserved application prefixes" do
    assert {:error, :reserved_prefix} = LanPathResolver.resolve(["api"])
    assert {:error, :reserved_prefix} = LanPathResolver.resolve(["workspaces", "alpha"])
  end

  test "rejects invalid path segments" do
    assert {:error, :invalid_path} = LanPathResolver.resolve([".."])
    assert {:error, :invalid_path} = LanPathResolver.resolve(["nested/path"])
  end

  test "rejects symlinks that escape the LAN root", %{root: root} do
    outside =
      Path.join(
        System.tmp_dir!(),
        "devide-lan-path-outside-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(outside)

    on_exit(fn -> File.rm_rf(outside) end)

    case File.ln_s(outside, Path.join(root, "outside")) do
      :ok ->
        assert {:error, :symlink_escape} = LanPathResolver.resolve(["outside"])

      {:error, :eexist} ->
        flunk("test symlink already exists")

      {:error, :eperm} ->
        :ok
    end
  end

  test "is disabled unless LAN mode and friendly paths are both enabled" do
    Application.put_env(:dev_ide, :lan_friendly_paths, false)
    assert {:error, :disabled} = LanPathResolver.resolve([])

    Application.put_env(:dev_ide, :lan_friendly_paths, true)
    Application.put_env(:dev_ide, :lan_mode, false)
    assert {:error, :disabled} = LanPathResolver.resolve([])
  end

  defp restore(key, nil), do: Application.delete_env(:dev_ide, key)
  defp restore(key, value), do: Application.put_env(:dev_ide, key, value)
end
