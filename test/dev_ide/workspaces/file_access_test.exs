defmodule DevIDE.Workspaces.FileAccessTest do
  use ExUnit.Case, async: true

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
end
