defmodule DevIDE.FilePanes.LinkResolverTest do
  use ExUnit.Case, async: false

  alias DevIDE.FilePanes.LinkResolver
  alias DevIDE.FilePanes.SuffixIndex

  setup do
    root =
      Path.join(System.tmp_dir!(), "link-resolver-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/foo.ex"), "defmodule Foo do\nend\n")
    File.write!(Path.join(root, "mix.exs"), "# mix\n")

    # Index the root synchronously so misses are terminal :not_found rather
    # than :pending (the async-build path is covered in SuffixIndexTest).
    SuffixIndex.rebuild(root)
    LinkResolver.clear_cache()

    on_exit(fn ->
      LinkResolver.clear_cache()
      File.rm_rf(root)
      Application.delete_env(:dev_ide, :file_link_cache_ttl_ms)
    end)

    {:ok, root: root}
  end

  describe "resolve/2" do
    test "resolves relative paths to existing regular files", %{root: root} do
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, "lib/foo.ex")
    end

    test "strips ./ prefixes", %{root: root} do
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, "./lib/foo.ex")
    end

    test "normalizes absolute paths under the root to relative", %{root: root} do
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, Path.join(root, "lib/foo.ex"))
    end

    test "rejects absolute paths outside the root", %{root: root} do
      assert {:error, :outside_root} = LinkResolver.resolve(root, "/etc/passwd")
    end

    test "rejects relative escapes", %{root: root} do
      assert {:error, :outside_root} = LinkResolver.resolve(root, "../outside.ex")
      assert {:error, :outside_root} = LinkResolver.resolve(root, "lib/../../outside.ex")
    end

    test "missing files and directories are :not_found", %{root: root} do
      assert {:error, :not_found} = LinkResolver.resolve(root, "lib/nope.ex")
      assert {:error, :not_found} = LinkResolver.resolve(root, "lib")
    end
  end

  describe "caching" do
    test "positive results are cached for the TTL", %{root: root} do
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, "lib/foo.ex")

      # Delete the file: the cached positive result keeps answering until the
      # TTL lapses.
      File.rm!(Path.join(root, "lib/foo.ex"))
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, "lib/foo.ex")
    end

    test "negative results are cached for the TTL", %{root: root} do
      assert {:error, :not_found} = LinkResolver.resolve(root, "lib/new.ex")

      # Creating the file does not flip the answer within the TTL window...
      File.write!(Path.join(root, "lib/new.ex"), "x")
      assert {:error, :not_found} = LinkResolver.resolve(root, "lib/new.ex")
    end

    test "entries expire after the TTL", %{root: root} do
      Application.put_env(:dev_ide, :file_link_cache_ttl_ms, 30)

      assert {:error, :not_found} = LinkResolver.resolve(root, "lib/new.ex")
      File.write!(Path.join(root, "lib/new.ex"), "x")

      Process.sleep(60)
      assert {:ok, "lib/new.ex"} = LinkResolver.resolve(root, "lib/new.ex")
    end
  end

  describe "suffix-index fallback" do
    test "bare file names resolve when unique in the workspace", %{root: root} do
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, "foo.ex")
    end

    test "subdir-relative paths resolve by trailing segments", %{root: root} do
      File.mkdir_p!(Path.join(root, "assets/js"))
      File.write!(Path.join(root, "assets/js/app.js"), "// app\n")
      SuffixIndex.rebuild(root)

      assert {:ok, "assets/js/app.js"} = LinkResolver.resolve(root, "js/app.js")
    end

    test "absolute paths outside the root (worktrees) resolve by suffix", %{root: root} do
      assert {:ok, "lib/foo.ex"} =
               LinkResolver.resolve(root, "/tmp/some-agent-worktree/lib/foo.ex")
    end

    test "ambiguous bare names stay unresolved", %{root: root} do
      File.mkdir_p!(Path.join(root, "other"))
      File.write!(Path.join(root, "other/foo.ex"), "x")
      SuffixIndex.rebuild(root)
      LinkResolver.clear_cache()

      assert {:error, :not_found} = LinkResolver.resolve(root, "foo.ex")
      # A directory-qualified suffix still disambiguates.
      assert {:ok, "other/foo.ex"} = LinkResolver.resolve(root, "other/foo.ex")
    end

    test "misses while the index is still building are not cached", %{root: root} do
      fresh = Path.join(root, "fresh-subroot")
      File.mkdir_p!(Path.join(fresh, "lib"))
      File.write!(Path.join(fresh, "lib/solo.ex"), "x")

      # First touch reports the plain miss and schedules a background build —
      # but must not negatively cache, or the link stays dead for a TTL.
      assert {:error, :not_found} = LinkResolver.resolve(fresh, "solo.ex")

      SuffixIndex.rebuild(fresh)
      assert {:ok, "lib/solo.ex"} = LinkResolver.resolve(fresh, "solo.ex")
    end

    test "outside-root misses keep their refusal while the index builds", %{root: root} do
      fresh = Path.join(root, "refusal-subroot")
      File.mkdir_p!(fresh)

      assert {:error, :outside_root} = LinkResolver.resolve(fresh, "/etc/passwd")
    end
  end

  describe "validate_frame/3" do
    test "keeps resolvable candidates (path rewritten relative), drops the rest", %{root: root} do
      candidates = [
        %{row: 0, from: 0, to: 9, path: "lib/foo.ex", line: 1},
        %{row: 0, from: 12, to: 20, path: "lib/nope.ex", line: nil},
        %{row: 1, from: 0, to: 30, path: Path.join(root, "mix.exs"), line: 3},
        %{row: 2, from: 0, to: 15, path: "/etc/passwd", line: nil}
      ]

      assert [
               %{row: 0, path: "lib/foo.ex", line: 1},
               %{row: 1, path: "mix.exs", line: 3}
             ] = LinkResolver.validate_frame(root, candidates)
    end

    test "caps uncached validations per frame; cached hits stay free", %{root: root} do
      # Warm the cache with one known path.
      assert {:ok, "lib/foo.ex"} = LinkResolver.resolve(root, "lib/foo.ex")

      for n <- 1..20, do: File.write!(Path.join(root, "lib/g#{n}.ex"), "x")

      fresh =
        Enum.map(1..20, fn n ->
          %{row: n, from: 0, to: 9, path: "lib/g#{n}.ex", line: nil}
        end)

      cached_tail = [%{row: 99, from: 0, to: 9, path: "lib/foo.ex", line: nil}]

      results = LinkResolver.validate_frame(root, fresh ++ cached_tail, max_new: 2)

      # Only 2 uncached validations ran; the cached path still resolves even
      # though it arrives after the budget is spent.
      assert Enum.map(results, & &1.row) == [1, 2, 99]

      # The budgeted-out candidates were NOT negatively cached — a later frame
      # can validate them.
      assert [%{row: 3} | _] =
               LinkResolver.validate_frame(root, Enum.drop(fresh, 2), max_new: 16)
    end
  end
end
