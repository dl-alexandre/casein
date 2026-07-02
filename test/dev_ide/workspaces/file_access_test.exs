defmodule DevIDE.Workspaces.FileAccessTest do
  # Serial: mutates process-global Application env (:ssh_runner).
  use DevIDE.TestCase, async: false

  alias DevIDE.Workspaces.FileAccess
  alias DevIDE.Test.FakeSshRunner

  @host "boxhost"
  @root "/data/workspaces/ws"

  setup do
    prev = Application.get_env(:dev_ide, :ssh_runner)
    Application.put_env(:dev_ide, :ssh_runner, FakeSshRunner)
    on_exit(fn -> Application.put_env(:dev_ide, :ssh_runner, prev) end)
    :ok
  end

  describe "ls/2 (remote)" do
    test "parses `ls -lAp` output, dirs first then files, alpha within group" do
      # Real `ls -lAp` date column is 3 tokens: "Jan  1 12:00".
      FakeSshRunner.set(fn @host, _argv ->
        {:ok,
         """
         total 12
         drwxr-xr-x 2 dev dev 4096 Jan  1 12:00 lib/
         -rw-r--r-- 1 dev dev  220 Jan  1 12:00 mix.exs
         drwxr-xr-x 2 dev dev 4096 Jan  1 12:00 config/
         -rw-r--r-- 1 dev dev   12 Jan  1 12:00 .gitignore
         """}
      end)

      assert {:ok, entries} = FileAccess.ls({:remote, @host, @root}, "")
      assert Enum.map(entries, & &1.name) == ["config", "lib", ".gitignore", "mix.exs"]
      assert Enum.map(entries, & &1.dir?) == [true, true, false, false]
      assert Enum.find(entries, &(&1.name == "mix.exs")).size == 220
    end

    test "propagates ssh failure" do
      FakeSshRunner.set(fn _, _ -> {:error, {:ssh_failed, 255, "boom"}} end)
      assert {:error, {:ssh_failed, 255, "boom"}} = FileAccess.ls({:remote, @host, @root}, "")
    end
  end

  describe "read_text/2 (remote)" do
    test "returns content + a content-hash version token" do
      FakeSshRunner.set(fn @host, _argv -> {:ok, "hello world\n"} end)

      assert {:ok, file} = FileAccess.read_text({:remote, @host, @root}, "a.txt")
      assert file.path == "a.txt"
      assert file.content == "hello world\n"
      assert file.size == 12
      assert file.version =~ ~r/^12:0:[0-9a-f]{16}$/
    end

    test "refuses binary content" do
      FakeSshRunner.set(fn _, _ -> {:ok, <<0, 1, 2, 0, 255>>} end)
      assert {:error, :binary} = FileAccess.read_text({:remote, @host, @root}, "x.bin")
    end
  end

  describe "write_text/4 (remote)" do
    test "writes when expected_version matches current on-disk version" do
      # First read_text call inside write_text computes current version.
      FakeSshRunner.set(fn _, _ -> {:ok, "old\n"} end)
      {:ok, %{version: current}} = FileAccess.read_text({:remote, @host, @root}, "f.txt")

      test_pid = self()

      FakeSshRunner.set_stdin(fn _, _argv, stdin ->
        send(test_pid, {:wrote, stdin})
        :ok
      end)

      assert {:ok, %{version: new_v, size: 4}} =
               FileAccess.write_text({:remote, @host, @root}, "f.txt", "new\n", current)

      assert_received {:wrote, "new\n"}
      refute new_v == current
    end

    test "returns :conflict when on-disk version differs from expected" do
      FakeSshRunner.set(fn _, _ -> {:ok, "changed underneath\n"} end)

      assert {:error, :conflict} =
               FileAccess.write_text(
                 {:remote, @host, @root},
                 "f.txt",
                 "x",
                 "0:0:deadbeefdeadbeef"
               )
    end

    test "refuses binary content before touching the remote" do
      FakeSshRunner.set(fn _, _ -> flunk("should not ssh for binary content") end)

      assert {:error, :binary} =
               FileAccess.write_text({:remote, @host, @root}, "f", <<0, 0, 0>>, "v")
    end
  end

  describe "search/3 (remote)" do
    test "parses `grep -rnIF` lines into Result structs with rel paths" do
      FakeSshRunner.set(fn @host, _argv ->
        {:ok,
         """
         #{@root}/lib/a.ex:12:  def hello do
         #{@root}/lib/b.ex:3:hello = 1
         """}
      end)

      assert {:ok, results} = FileAccess.search({:remote, @host, @root}, "hello", [])
      assert Enum.map(results, & &1.path) == ["lib/a.ex", "lib/b.ex"]
      assert Enum.map(results, & &1.line) == [12, 3]
      assert hd(results).preview == "  def hello do"
    end

    test "rejects too-short queries without ssh" do
      FakeSshRunner.set(fn _, _ -> flunk("should not ssh for short query") end)
      assert {:error, :too_short} = FileAccess.search({:remote, @host, @root}, "h", [])
    end
  end

  describe "git_status_short/1 (remote)" do
    test "parses porcelain short status" do
      FakeSshRunner.set(fn @host, _argv ->
        {:ok, " M lib/a.ex\n?? new.txt\n"}
      end)

      assert {:ok, entries} = FileAccess.git_status_short({:remote, @host, @root})

      assert entries == [
               %{x: " ", y: "M", path: "lib/a.ex"},
               %{x: "?", y: "?", path: "new.txt"}
             ]
    end
  end

  describe "git_diff/2 (remote)" do
    test "returns diff output" do
      FakeSshRunner.set(fn @host, _argv -> {:ok, "diff --git a/x b/x\n"} end)
      assert {:ok, "diff --git a/x b/x\n"} = FileAccess.git_diff({:remote, @host, @root}, "x")
    end
  end

  describe "label/1" do
    test "renders local and remote locs" do
      assert FileAccess.label({:local, "/w/ws"}) == "/w/ws"
      assert FileAccess.label({:remote, "boxhost", "/data/ws"}) == "boxhost:/data/ws"
    end
  end

  describe "local file operations" do
    setup do
      root =
        Path.join(
          System.tmp_dir!(),
          "fa-local-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(Path.join(root, "lib"))
      File.mkdir_p!(Path.join(root, "config"))
      File.write!(Path.join(root, "mix.exs"), "defmodule M do\nend\n")
      File.write!(Path.join(root, ".gitignore"), "/_build\n")
      File.write!(Path.join([root, "lib", "a.ex"]), "hello world\n")
      File.write!(Path.join(root, "bin.dat"), <<0, 1, 2, 0, 255>>)

      on_exit(fn -> File.rm_rf!(root) end)

      {:ok, root: root, loc: {:local, root}}
    end

    test "ls/2 lists entries sorted with dir? and size", %{loc: loc} do
      assert {:ok, entries} = FileAccess.ls(loc, "")

      by_name = Map.new(entries, &{&1.name, &1})
      assert by_name["lib"].dir? == true
      assert by_name["lib"].size == nil
      assert by_name["mix.exs"].dir? == false
      assert by_name["mix.exs"].size == byte_size("defmodule M do\nend\n")

      # ls/2 sorts names alphabetically (no dir-first grouping locally).
      assert Enum.map(entries, & &1.name) == Enum.sort(Enum.map(entries, & &1.name))
    end

    test "ls/2 into a subdirectory", %{loc: loc} do
      assert {:ok, entries} = FileAccess.ls(loc, "lib")
      assert Enum.map(entries, & &1.name) == ["a.ex"]
      assert hd(entries).dir? == false
      assert hd(entries).size == byte_size("hello world\n")
    end

    test "ls/2 default subpath arg covers the empty string", %{loc: loc} do
      assert {:ok, entries} = FileAccess.ls(loc)
      assert Enum.any?(entries, &(&1.name == "mix.exs"))
    end

    test "ls/2 rejects parent traversal via PathSafety", %{loc: loc} do
      assert {:error, :outside_root} = FileAccess.ls(loc, "../etc")
    end

    test "ls/2 returns posix error for a missing directory", %{loc: loc} do
      assert {:error, :enoent} = FileAccess.ls(loc, "nope")
    end

    test "read/2 returns raw file bytes", %{loc: loc} do
      assert {:ok, "hello world\n"} = FileAccess.read(loc, "lib/a.ex")
    end

    test "read/2 returns binary content unchanged (no binary refusal)", %{loc: loc} do
      assert {:ok, <<0, 1, 2, 0, 255>>} = FileAccess.read(loc, "bin.dat")
    end

    test "read/2 rejects traversal", %{loc: loc} do
      assert {:error, :outside_root} = FileAccess.read(loc, "../../etc/passwd")
    end

    test "read/2 missing file returns :enoent", %{loc: loc} do
      assert {:error, :enoent} = FileAccess.read(loc, "missing.txt")
    end

    test "read_text/2 returns text-file shape with a version token", %{loc: loc} do
      assert {:ok, file} = FileAccess.read_text(loc, "lib/a.ex")
      assert file.path == "lib/a.ex"
      assert file.content == "hello world\n"
      assert file.size == byte_size("hello world\n")
      assert is_binary(file.version)
      assert file.mtime != nil
    end

    test "read_text/2 refuses binary content", %{loc: loc} do
      assert {:error, :binary} = FileAccess.read_text(loc, "bin.dat")
    end

    test "read_text/2 on a directory returns :not_a_file", %{loc: loc} do
      assert {:error, :not_a_file} = FileAccess.read_text(loc, "lib")
    end

    test "read_text/2 rejects traversal", %{loc: loc} do
      assert {:error, :outside_root} = FileAccess.read_text(loc, "../secret")
    end

    test "write_text/4 writes when expected_version matches, returns new version", %{loc: loc} do
      {:ok, %{version: v}} = FileAccess.read_text(loc, "lib/a.ex")

      assert {:ok, %{version: new_v, size: size}} =
               FileAccess.write_text(loc, "lib/a.ex", "goodbye\n", v)

      assert size == byte_size("goodbye\n")
      refute new_v == v
      assert {:ok, %{content: "goodbye\n"}} = FileAccess.read_text(loc, "lib/a.ex")
    end

    test "write_text/4 returns :conflict on stale version", %{loc: loc} do
      assert {:error, :conflict} =
               FileAccess.write_text(loc, "lib/a.ex", "x\n", "0:0:deadbeefdeadbeef")
    end

    test "write_text/4 rejects traversal", %{loc: loc} do
      assert {:error, :outside_root} =
               FileAccess.write_text(loc, "../escape.txt", "x\n", "v")
    end

    test "search/3 rejects too-short queries without touching the FS", %{loc: loc} do
      assert {:error, :too_short} = FileAccess.search(loc, "h", [])
    end
  end
end
