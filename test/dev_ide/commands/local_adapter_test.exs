defmodule DevIDE.Commands.LocalAdapterTest do
  use ExUnit.Case, async: false

  alias DevIDE.Commands.LocalAdapter

  test "streams command output and reports normal exit" do
    {:ok, cwd} = File.cwd()

    assert {:ok, ref, handle} =
             LocalAdapter.spawn(cwd, ["/bin/sh", "-c", "printf adapter-ok"], self())

    assert is_integer(handle.ospid)
    assert_receive {:cmd_data, ^ref, :stdout, "adapter-ok"}, 5_000
    assert_receive {:cmd_exit, ^ref, 0}, 5_000
  end

  test "reports non-zero exit status" do
    {:ok, cwd} = File.cwd()

    assert {:ok, ref, _handle} =
             LocalAdapter.spawn(cwd, ["/bin/sh", "-c", "exit 42"], self())

    assert_receive {:cmd_exit, ^ref, 42}, 5_000
  end

  test "resolves allowlisted-style executables from PATH without a shell" do
    {:ok, cwd} = File.cwd()

    assert {:ok, ref, _handle} = LocalAdapter.spawn(cwd, ["sh", "-c", "printf path-ok"], self())

    assert_receive {:cmd_data, ^ref, :stdout, "path-ok"}, 5_000
    assert_receive {:cmd_exit, ^ref, 0}, 5_000
  end
end
