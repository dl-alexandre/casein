defmodule Casein.FilePanes.SuffixIndexTest do
  use ExUnit.Case, async: false

  alias Casein.FilePanes.SuffixIndex

  setup do
    root =
      Path.join(System.tmp_dir!(), "suffix-index-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, "lib/nested"))
    File.mkdir_p!(Path.join(root, "assets/js"))
    File.write!(Path.join(root, "lib/foo.ex"), "# foo\n")
    File.write!(Path.join(root, "lib/nested/target.ex"), "# target\n")
    File.write!(Path.join(root, "assets/js/app.js"), "// app\n")

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  describe "lookup/2" do
    test "returns :pending before the first build completes", %{root: root} do
      # A never-indexed root answers :pending and schedules a background
      # build; poll (bounded) until that build lands.
      assert {:error, :pending} = SuffixIndex.lookup(root, "target.ex")

      assert await(fn -> SuffixIndex.lookup(root, "target.ex") end) ==
               {:ok, "lib/nested/target.ex"}
    end

    test "bare names resolve when unique", %{root: root} do
      SuffixIndex.rebuild(root)

      assert {:ok, "lib/nested/target.ex"} = SuffixIndex.lookup(root, "target.ex")
      assert {:ok, "assets/js/app.js"} = SuffixIndex.lookup(root, "app.js")
    end

    test "suffixes with directory segments resolve and disambiguate", %{root: root} do
      File.mkdir_p!(Path.join(root, "a"))
      File.mkdir_p!(Path.join(root, "b"))
      File.write!(Path.join(root, "a/dup.ex"), "a")
      File.write!(Path.join(root, "b/dup.ex"), "b")
      SuffixIndex.rebuild(root)

      assert {:error, :ambiguous} = SuffixIndex.lookup(root, "dup.ex")
      assert {:ok, "a/dup.ex"} = SuffixIndex.lookup(root, "a/dup.ex")
      assert {:ok, "b/dup.ex"} = SuffixIndex.lookup(root, "b/dup.ex")
    end

    test "unknown names are :not_found", %{root: root} do
      SuffixIndex.rebuild(root)

      assert {:error, :not_found} = SuffixIndex.lookup(root, "nope.ex")
      assert {:error, :not_found} = SuffixIndex.lookup(root, "wrong/foo.ex")
    end

    test "ignored directories are not indexed", %{root: root} do
      File.mkdir_p!(Path.join(root, "_build/dev"))
      File.write!(Path.join(root, "_build/dev/hidden.ex"), "x")
      SuffixIndex.rebuild(root)

      assert {:error, :not_found} = SuffixIndex.lookup(root, "hidden.ex")
    end

    test "symlinked directories are never followed", %{root: root} do
      outside =
        Path.join(System.tmp_dir!(), "suffix-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.ex"), "x")
      on_exit(fn -> File.rm_rf(outside) end)

      case File.ln_s(outside, Path.join(root, "escape")) do
        :ok ->
          SuffixIndex.rebuild(root)
          assert {:error, :not_found} = SuffixIndex.lookup(root, "secret.ex")

        {:error, _} ->
          # Filesystem without symlink support: nothing to assert.
          :ok
      end
    end

    test "rebuild sweeps entries for deleted files", %{root: root} do
      SuffixIndex.rebuild(root)
      assert {:ok, "lib/foo.ex"} = SuffixIndex.lookup(root, "foo.ex")

      File.rm!(Path.join(root, "lib/foo.ex"))
      SuffixIndex.rebuild(root)

      assert {:error, :not_found} = SuffixIndex.lookup(root, "foo.ex")
    end
  end

  # Bounded poll for a background build; generous ceiling, no fixed sleeps.
  defp await(fun, deadline_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    poll(fun, deadline)
  end

  defp poll(fun, deadline) do
    case fun.() do
      {:error, :pending} ->
        if System.monotonic_time(:millisecond) > deadline do
          {:error, :pending}
        else
          Process.sleep(10)
          poll(fun, deadline)
        end

      result ->
        result
    end
  end
end
