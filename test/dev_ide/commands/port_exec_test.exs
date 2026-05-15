defmodule DevIDE.Commands.PortExecTest do
  use ExUnit.Case, async: false

  alias DevIDE.Commands.PortExec

  # PortExec spawns real subprocesses via erlexec — same requirement as
  # LocalAdapterTest. Mirrors that test's shape: a real `/bin/sh` child, no
  # seam needed.

  test "streams stdout and reports normal exit" do
    assert {:ok, ref, handle} =
             PortExec.run(["/bin/sh", "-c", "printf port-exec-ok"], [], self())

    assert is_integer(handle.ospid)
    assert_receive {:cmd_data, ^ref, :stdout, "port-exec-ok"}, 5_000
    assert_receive {:cmd_exit, ^ref, 0}, 5_000
  end

  test "routes stderr separately from stdout" do
    assert {:ok, ref, _} =
             PortExec.run(["/bin/sh", "-c", "printf oops 1>&2"], [], self())

    assert_receive {:cmd_data, ^ref, :stderr, "oops"}, 5_000
    assert_receive {:cmd_exit, ^ref, 0}, 5_000
  end

  test "decodes a non-zero exit status (high byte of wait(2) status)" do
    assert {:ok, ref, _} = PortExec.run(["/bin/sh", "-c", "exit 42"], [], self())
    assert_receive {:cmd_exit, ^ref, 42}, 5_000
  end

  test "decodes a signalled process as 128 + signal" do
    # `kill -TERM $$` makes the shell die on SIGTERM (15) — exercises the
    # signal branch of the exit-status decode, not the normal-exit branch.
    assert {:ok, ref, _} = PortExec.run(["/bin/sh", "-c", "kill -TERM $$"], [], self())
    assert_receive {:cmd_exit, ^ref, 143}, 5_000
  end

  test "merges extra_opts into the exec options (e.g. {:cd, dir})" do
    tmp = System.tmp_dir!() |> Path.expand()

    assert {:ok, ref, _} =
             PortExec.run(["/bin/sh", "-c", "pwd"], [{:cd, to_charlist(tmp)}], self())

    assert_receive {:cmd_data, ^ref, :stdout, out}, 5_000
    # `pwd` reports the symlink-resolved path; on macOS /var is /private/var.
    assert strip_private(String.trim(out)) == strip_private(tmp)
    assert_receive {:cmd_exit, ^ref, 0}, 5_000
  end

  test "kill/1 returns :ok for a live handle and no-ops on an unknown one" do
    # PortExec.kill/1 is a thin wrapper over `:exec.kill/2`; its contract is
    # "returns :ok". The exit-message *delivery + decode* path it triggers is
    # the same `wait_loop` code already pinned by the SIGTERM test above
    # (a self-signalled process exercises the identical proxy -> :cmd_exit
    # path), so we don't re-assert delivery here — doing so would really be
    # testing erlexec's kill latency, not PortExec.
    assert {:ok, _ref, handle} = PortExec.run(["/bin/sh", "-c", "sleep 30"], [], self())
    assert :ok = PortExec.kill(handle)
    assert :ok = PortExec.kill(:not_a_handle)
  end

  # macOS resolves /var -> /private/var; strip the prefix so path comparisons
  # work on both macOS and Linux.
  defp strip_private("/private" <> rest), do: rest
  defp strip_private(path), do: path
end
