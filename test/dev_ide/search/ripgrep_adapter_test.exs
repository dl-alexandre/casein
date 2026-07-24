defmodule Casein.Search.RipgrepAdapterTest do
  use Casein.TestCase, async: false

  alias Casein.Search.RipgrepAdapter

  setup do
    root = Path.join(System.tmp_dir!(), "rg-#{System.unique_integer([:positive])}")
    bin_dir = Path.join(root, "bin")
    File.mkdir_p!(bin_dir)
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join([root, "lib", "a.ex"]), "defmodule A do\n  def needle, do: :ok\nend\n")
    prev_path = System.get_env("PATH")
    System.put_env("PATH", bin_dir <> ":" <> (prev_path || ""))

    on_exit(fn ->
      if prev_path, do: System.put_env("PATH", prev_path), else: System.delete_env("PATH")
      File.rm_rf!(root)
    end)

    {:ok, root: root, bin_dir: bin_dir}
  end

  test "available? reflects whether rg is on PATH", %{bin_dir: bin_dir} do
    write_fake_rg!(bin_dir, "#!/bin/sh\nexit 0\n")
    assert RipgrepAdapter.available?()

    with_path("/nonexistent-rg-path", fn ->
      refute RipgrepAdapter.available?()
    end)
  end

  test "rg missing -> :rg_missing", %{root: root} do
    with_path("/nonexistent-rg-path", fn ->
      assert {:error, :rg_missing} = RipgrepAdapter.search(root, "needle", [])
    end)
  end

  test "finds matches and parses rg json output", %{root: root, bin_dir: bin_dir} do
    abs = Path.join(root, "lib/a.ex")

    write_fake_rg!(bin_dir, """
    #!/bin/sh
    printf '%s\\n' '{"type":"match","data":{"path":{"text":"#{abs}"},"line_number":2,"lines":{"text":"  def needle, do: :ok\\n"},"submatches":[{"start":5}]}}'
    exit 0
    """)

    {:ok, results} = RipgrepAdapter.search(root, "needle", timeout_ms: 5_000, result_cap: 100)
    [match] = results

    assert match.path == "lib/a.ex"
    assert match.line == 2
    assert match.column == 6
    assert match.preview =~ "needle"
  end

  test "returns empty list for no matches", %{root: root, bin_dir: bin_dir} do
    write_fake_rg!(bin_dir, "#!/bin/sh\nexit 1\n")
    assert {:ok, []} = RipgrepAdapter.search(root, "no_such_match_xyz_123", [])
  end

  test "times out when rg exceeds timeout_ms", %{root: root, bin_dir: bin_dir} do
    write_fake_rg!(bin_dir, "#!/bin/sh\nsleep 60\n")

    assert {:error, :timeout} =
             RipgrepAdapter.search(root, "needle", timeout_ms: 1, result_cap: 10)
  end

  test "result_cap limits returned matches", %{root: root, bin_dir: bin_dir} do
    abs = Path.join(root, "lib/a.ex")

    write_fake_rg!(bin_dir, """
    #!/bin/sh
    for i in 1 2 3 4 5; do
      printf '%s\\n' '{"type":"match","data":{"path":{"text":"#{abs}"},"line_number":'"$i"',"lines":{"text":"needle '"$i"'\\n"},"submatches":[{"start":0}]}}'
    done
    exit 0
    """)

    assert {:ok, results} = RipgrepAdapter.search(root, "needle", result_cap: 3)
    assert length(results) == 3
  end

  test "result_cap of zero returns empty list", %{root: root, bin_dir: bin_dir} do
    abs = Path.join(root, "lib/a.ex")

    write_fake_rg!(bin_dir, """
    #!/bin/sh
    printf '%s\\n' '{"type":"match","data":{"path":{"text":"#{abs}"},"line_number":1,"lines":{"text":"needle\\n"},"submatches":[{"start":0}]}}'
    exit 0
    """)

    assert {:ok, []} = RipgrepAdapter.search(root, "needle", result_cap: 0)
  end

  test "drops matches outside workspace root", %{root: root, bin_dir: bin_dir} do
    outside = Path.join(System.tmp_dir!(), "secret-#{System.unique_integer([:positive])}.ex")

    write_fake_rg!(bin_dir, """
    #!/bin/sh
    printf '%s\\n' '{"type":"match","data":{"path":{"text":"#{outside}"},"line_number":1,"lines":{"text":"needle\\n"},"submatches":[{"start":0}]}}'
    exit 0
    """)

    assert {:ok, []} = RipgrepAdapter.search(root, "needle", [])
  end

  test "ignores malformed json lines and uses bytes/text fallbacks", %{
    root: root,
    bin_dir: bin_dir
  } do
    abs = Path.join(root, "lib/a.ex")

    write_fake_rg!(bin_dir, """
    #!/bin/sh
    printf '%s\\n' 'not-json'
    printf '%s\\n' '{"type":"match","data":{"path":{"bytes":"#{abs}"},"line_number":3,"lines":{"bytes":"preview bytes\\n"},"submatches":[]}}'
    exit 0
    """)

    {:ok, [match]} = RipgrepAdapter.search(root, "needle", [])
    assert match.path == "lib/a.ex"
    assert match.line == 3
    assert match.column == nil
    assert match.preview =~ "preview"
  end

  defp write_fake_rg!(bin_dir, body) do
    rg = Path.join(bin_dir, "rg")
    File.write!(rg, body)
    File.chmod!(rg, 0o755)
  end

  defp with_path(path, fun) do
    previous = System.get_env("PATH")
    System.put_env("PATH", path)

    try do
      fun.()
    after
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
    end
  end
end
