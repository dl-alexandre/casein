defmodule DevIDE.Search.RipgrepAdapterTest do
  use ExUnit.Case, async: false

  alias DevIDE.Search.RipgrepAdapter

  @rg_present? not is_nil(System.find_executable("rg"))

  setup do
    root = Path.join(System.tmp_dir!(), "rg-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    File.mkdir_p!(Path.join(root, "_build"))
    File.mkdir_p!(Path.join(root, ".git"))
    File.write!(Path.join([root, "lib", "a.ex"]), "defmodule A do\n  def needle, do: :ok\nend\n")
    File.write!(Path.join([root, "_build", "x.ex"]), "needle inside ignored\n")
    File.write!(Path.join([root, ".git", "config"]), "needle in git\n")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  if @rg_present? do
    test "finds matches and excludes ignored dirs", %{root: root} do
      {:ok, results} = RipgrepAdapter.search(root, "needle", timeout_ms: 5_000, result_cap: 100)
      paths = Enum.map(results, & &1.path)

      assert "lib/a.ex" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "_build/"))
      refute Enum.any?(paths, &String.starts_with?(&1, ".git/"))
    end

    test "returns empty list for no matches", %{root: root} do
      assert {:ok, []} = RipgrepAdapter.search(root, "no_such_match_xyz_123", [])
    end

    test "result line/column point to the match", %{root: root} do
      {:ok, results} = RipgrepAdapter.search(root, "needle", [])
      [r | _] = Enum.filter(results, &(&1.path == "lib/a.ex"))
      assert r.line == 2
      assert r.column == nil or r.column > 0
      assert r.preview =~ "needle"
    end
  else
    test "rg missing -> :rg_missing", %{root: root} do
      assert {:error, :rg_missing} = RipgrepAdapter.search(root, "needle", [])
    end
  end

  test "available? matches binary presence" do
    assert RipgrepAdapter.available?() == @rg_present?
  end
end
