defmodule ExecCtl.PortTest do
  use Casein.TestCase, async: false

  alias ExecCtl.Port

  test "streams stdout and reports normal exit" do
    assert {:ok, ref, handle} =
             Port.run(["/bin/sh", "-c", "printf exec-ctl-ok"], [], self())

    assert is_integer(handle.ospid)
    assert_receive {:cmd_data, ^ref, :stdout, "exec-ctl-ok"}, 5_000
    assert_receive {:cmd_exit, ^ref, 0}, 5_000
  end

  test "kill/1 is a no-op for unknown handles" do
    assert :ok = Port.kill(:not_a_handle)
    assert :ok = Port.kill(%{})
  end
end
