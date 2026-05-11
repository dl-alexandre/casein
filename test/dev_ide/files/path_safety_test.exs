defmodule DevIDE.Files.PathSafetyTest do
  use ExUnit.Case, async: true
  alias DevIDE.Files.PathSafety

  setup do
    root = Path.join(System.tmp_dir!(), "ps-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "sub"))
    File.write!(Path.join(root, "ok.txt"), "hello")
    File.write!(Path.join(root, "binary.bin"), <<1, 2, 0, 3, 4>>)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "resolves a normal relative path", %{root: root} do
    assert {:ok, abs} = PathSafety.resolve(root, "ok.txt")
    assert abs == Path.expand(Path.join(root, "ok.txt"))
  end

  test "rejects path traversal", %{root: root} do
    assert {:error, :outside_root} = PathSafety.resolve(root, "../etc/passwd")
    assert {:error, :outside_root} = PathSafety.resolve(root, "sub/../../escape")
  end

  test "rejects symlinks that escape the root", %{root: root} do
    outside = Path.join(System.tmp_dir!(), "ps-outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret"), "nope")
    File.ln_s!(outside, Path.join(root, "escape_link"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:error, :symlink_escape} = PathSafety.resolve(root, "escape_link/secret")
  end

  test "ignored_dir? matches the standard noisy dirs" do
    assert PathSafety.ignored_dir?(".git")
    assert PathSafety.ignored_dir?("_build")
    assert PathSafety.ignored_dir?("deps")
    assert PathSafety.ignored_dir?("node_modules")
    refute PathSafety.ignored_dir?("lib")
  end

  test "ignored_path? catches priv/static/cache" do
    assert PathSafety.ignored_path?("priv/static/cache")
    assert PathSafety.ignored_path?("priv/static/cache/whatever.png")
    refute PathSafety.ignored_path?("priv/static/images/logo.png")
  end

  test "likely_binary? sniffs NUL bytes" do
    assert PathSafety.likely_binary?(<<1, 2, 0, 3>>)
    refute PathSafety.likely_binary?("hello world")
  end
end
