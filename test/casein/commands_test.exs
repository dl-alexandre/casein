defmodule Casein.CommandsTest do
  # async: false — the spawn/3 tests start real OS subprocesses via erlexec and
  # link the spawn proxy into the test process.
  use Casein.TestCase, async: false
  alias Casein.Commands

  setup_all do
    # erlexec ships as an `extra_applications` entry, so it is normally already
    # up with the app — ensure it explicitly so this file is self-contained.
    {:ok, _} = Application.ensure_all_started(:erlexec)
    :ok
  end

  test "allowlist exposes only safe command ids" do
    assert Map.keys(Commands.allowlist()) |> Enum.sort() ==
             ~w(agent assets.build claude clauded codex compile dogfood.fail format grok opencode precommit test)
             |> Enum.sort()
  end

  test "allowed?/1 only accepts allowlist ids" do
    assert Commands.allowed?("test")
    refute Commands.allowed?("rm -rf /")
    refute Commands.allowed?("compile; echo pwned")
  end

  test "argv_for/1 returns argv lists, never strings to be shell-parsed" do
    {:ok, argv} = Commands.argv_for("test")
    assert is_list(argv)
    assert Enum.all?(argv, &is_binary/1)
  end

  test "argv_for/1 returns :error for an unknown id" do
    assert :error = Commands.argv_for("not-a-real-id")
  end

  describe "spawn/3 happy path (real subprocess)" do
    setup do
      root = Path.join(System.tmp_dir!(), "cmd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "runs an absolute-path command, streams stdout, then exits 0", %{root: root} do
      assert {:ok, ref, handle} = Commands.spawn(root, ["/bin/echo", "hello"], self())
      assert is_reference(ref)
      assert %{exec_pid: _, ospid: ospid, proxy_pid: proxy} = handle
      assert is_integer(ospid)
      assert is_pid(proxy)

      # stdout is forwarded line-buffered to the subscriber (this test pid).
      assert_receive {:cmd_data, ^ref, :stdout, data}, 5_000
      assert IO.iodata_to_binary(data) =~ "hello"

      # erlexec packs exit; /bin/echo exits 0.
      assert_receive {:cmd_exit, ^ref, 0}, 5_000
    end

    test "resolves a bare command name via PATH (System.find_executable)", %{root: root} do
      # "true" has no slash, so resolve_executable hits the find_executable branch.
      assert {:ok, ref, _handle} = Commands.spawn(root, ["true"], self())
      assert_receive {:cmd_exit, ^ref, 0}, 5_000
    end

    test "kill/1 on a live handle returns :ok", %{root: root} do
      assert {:ok, _ref, handle} = Commands.spawn(root, ["/bin/sleep", "5"], self())
      assert :ok = Commands.kill(handle)
    end
  end

  describe "spawn/3 error branches" do
    setup do
      root = Path.join(System.tmp_dir!(), "cmd-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root}
    end

    test "non-existent root yields {:error, :no_root}" do
      missing = Path.join(System.tmp_dir!(), "missing-#{System.unique_integer([:positive])}")
      refute File.dir?(missing)
      assert {:error, :no_root} = Commands.spawn(missing, ["/bin/echo", "x"], self())
    end

    test "unresolvable bare command yields executable_not_found", %{root: root} do
      bogus = "devide-no-such-binary-#{System.unique_integer([:positive])}"
      assert {:error, {:executable_not_found, ^bogus}} = Commands.spawn(root, [bogus], self())
    end

    test "bad argument shapes hit the {:error, :bad_args} fallback", %{root: root} do
      # Empty argv (no [bin | args] match), non-binary bin, non-pid subscriber,
      # non-binary root all fall through to the catch-all clause.
      assert {:error, :bad_args} = Commands.spawn(root, [], self())
      assert {:error, :bad_args} = Commands.spawn(root, [123], self())
      assert {:error, :bad_args} = Commands.spawn(root, ["/bin/echo"], :not_a_pid)
      assert {:error, :bad_args} = Commands.spawn(:not_a_binary, ["/bin/echo"], self())
    end
  end

  describe "kill/1 fallback" do
    test "kill of a non-handle term is a no-op :ok" do
      assert :ok = Commands.kill(:not_a_handle)
      assert :ok = Commands.kill(%{no: :ospid})
      assert :ok = Commands.kill(nil)
    end
  end
end
